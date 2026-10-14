import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Serializes profile-owned reads and writes, including background isolates.
/// Callers must not nest operations on the same path.
class ProfileArtifacts {
  ProfileArtifacts(this.profilePath);
  final String profilePath;
  String get sourcePath =>
      profilePath.replaceFirst(RegExp(r'\.yaml$'), '.template-source-v1.yaml');
  Directory get _journal => Directory('$profilePath.transaction');
  static final Map<String, Future<void>> _queues = {};

  Future<T> run<T>(Future<T> Function(ProfileArtifacts files) operation) async {
    final previous = _queues[profilePath] ?? Future<void>.value();
    final done = Completer<void>();
    _queues[profilePath] = done.future;
    await previous;
    RandomAccessFile? lock;
    var locked = false;
    try {
      await File(profilePath).parent.create(recursive: true);
      lock = await File('$profilePath.lock').open(mode: FileMode.append);
      await lock.lock(FileLock.blockingExclusive);
      locked = true;
      await _recover();
      return await operation(this);
    } finally {
      try {
        if (lock != null) {
          try {
            if (locked) await lock.unlock();
          } finally {
            await lock.close();
          }
        }
      } finally {
        done.complete();
        if (identical(_queues[profilePath], done.future)) {
          final removed = _queues.remove(profilePath);
          if (removed != null) unawaited(removed);
        }
      }
    }
  }

  Future<({Uint8List? profile, Uint8List? source})> read() async => (
    profile: await _optional(File(profilePath)),
    source: await _optional(File(sourcePath)),
  );

  Future<Uint8List?> _optional(File file) async =>
      await file.exists() ? await file.readAsBytes() : null;

  Future<void> _restore(String name, String target) async {
    final old = File('${_journal.path}/$name');
    final file = File(target);
    if (await old.exists()) {
      await file.writeAsBytes(await old.readAsBytes(), flush: true);
    } else if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> _recover() async {
    final retired = Directory('$profilePath.transaction-retired');
    if (await retired.exists()) await retired.delete(recursive: true);
    if (!await _journal.exists()) return;
    if (await File('${_journal.path}/ready').exists() &&
        !await File('${_journal.path}/committed').exists()) {
      await _restore('profile', profilePath);
      await _restore('source', sourcePath);
    }
    // Retire the entire journal before recursive cleanup. A process exit
    // mid-delete must never turn a committed journal into an undo journal.
    await _journal.rename(retired.path);
    await retired.delete(recursive: true);
  }

  /// Undo journal + explicit commit point, NOT an atomic two-file rename.
  /// Before commit, a handled fault or next cooperating reader rolls back.
  /// Flush is used, but directory fsync/power-loss durability is not promised.
  Future<void> publish(Uint8List? profile, Uint8List? source) async {
    final prior = await read();
    await _journal.create();
    try {
      if (prior.profile != null) {
        await File(
          '${_journal.path}/profile',
        ).writeAsBytes(prior.profile!, flush: true);
      }
      if (prior.source != null) {
        await File(
          '${_journal.path}/source',
        ).writeAsBytes(prior.source!, flush: true);
      }
      await File('${_journal.path}/ready').writeAsString('v1', flush: true);
      if (source == null) {
        if (await File(sourcePath).exists()) await File(sourcePath).delete();
      } else {
        await File(sourcePath).writeAsBytes(source, flush: true);
      }
      if (profile == null) {
        if (await File(profilePath).exists()) await File(profilePath).delete();
      } else {
        final stage = File('${_journal.path}/new-profile');
        await stage.writeAsBytes(profile, flush: true);
        await stage.copy(profilePath);
        final target = await File(profilePath).open(mode: FileMode.append);
        try {
          await target.flush();
        } finally {
          await target.close();
        }
      }
      final commit = File('${_journal.path}/commit-stage');
      await commit.writeAsString('v1', flush: true);
      await commit.rename('${_journal.path}/committed');
    } catch (_) {
      await _recover();
      rethrow;
    }
    // A cleanup fault after commit must not report the committed update failed.
    try {
      await _recover();
    } on FileSystemException {
      /* recovered on next read */
    }
  }
}
