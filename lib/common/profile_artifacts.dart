import 'dart:async';
import 'dart:io';
import 'dart:math';
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
  static const _lockTimeout = Duration(seconds: 30);
  static const _retryDelay = Duration(milliseconds: 20);

  /// Exclusive creation is O_CREAT|O_EXCL on POSIX (not process-owned fcntl).
  /// All cooperating isolates/processes acquire it BEFORE opening the OS lock.
  /// A killed isolate/process leaves the marker: acquisition then fails closed.
  /// Never steal by age/PID. Administrative removal requires ALL profile users
  /// stopped; no automatic recovery of an abandoned marker is promised.
  Future<T> run<T>(Future<T> Function(ProfileArtifacts files) operation) async {
    final previous = _queues[profilePath] ?? Future<void>.value();
    final done = Completer<void>();
    _queues[profilePath] = done.future;
    try {
      await previous.timeout(_lockTimeout);
      return await _runLocked(operation);
    } finally {
      // A timed-out waiter must not let a successor overtake the still-active
      // predecessor. Completing its queue slot remains chained to predecessor.
      unawaited(
        previous.then((_) {
          done.complete();
          if (identical(_queues[profilePath], done.future)) {
            _queues.remove(profilePath);
          }
        }),
      );
    }
  }

  Future<T> _runLocked<T>(
    Future<T> Function(ProfileArtifacts files) operation,
  ) async {
    final marker = File('$profilePath.isolate-lock');
    final clock = Stopwatch()..start();
    final nonce = List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final owner = '$pid:$nonce';
    var acquired = false;
    var ownerWritten = false;
    var handleClosed = true;
    RandomAccessFile? lock;
    var locked = false;
    Future<void> retry() async {
      if (clock.elapsed >= _lockTimeout) {
        throw TimeoutException(
          'Profile artifact lock unavailable: $profilePath',
          _lockTimeout,
        );
      }
      await Future<void>.delayed(_retryDelay);
    }

    try {
      await File(profilePath).parent.create(recursive: true);
      while (!acquired) {
        try {
          await marker.create(exclusive: true);
          acquired = true;
        } on PathExistsException {
          await retry();
        }
      }
      await marker.writeAsString(owner, flush: true);
      ownerWritten = true;
      lock = await File('$profilePath.lock').open(mode: FileMode.append);
      handleClosed = false;
      while (!locked) {
        try {
          // Keep the OS lock for cross-process/legacy cooperating callers, but
          // never block a Dart IO worker indefinitely while acquiring it.
          await lock.lock(FileLock.exclusive);
          locked = true;
        } on FileSystemException {
          await retry();
        }
      }
      await _recover();
      return await operation(this);
    } finally {
      try {
        if (lock != null) {
          try {
            if (locked) await lock.unlock();
          } finally {
            await lock.close();
            handleClosed = true;
          }
        }
      } finally {
        if (acquired && handleClosed) {
          // No contenders delete/rename markers. Delete only our own marker,
          // after OS unlock/close, so a successor never opens that handle early.
          // If owner write failed, exclusive creation still proves ownership.
          // A changed marker is retained fail-closed; never delete another
          // owner's marker, even if external interference broke the protocol.
          if (!ownerWritten || await marker.readAsString() == owner) {
            await marker.delete();
          }
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
