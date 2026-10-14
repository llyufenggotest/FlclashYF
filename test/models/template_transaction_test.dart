import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:isolate';
import 'package:fl_clash/common/profile_artifacts.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => root;
}

final class _FaultIO extends IOOverrides {
  _FaultIO(this.target);
  final String target;
  @override
  File createFile(String path) => _File(super.createFile(path), target);
}

class _File implements File {
  _File(this.real, this.target);
  final File real;
  final String target;
  @override
  String get path => real.path;
  @override
  Directory get parent => real.parent;
  @override
  Future<bool> exists() => real.exists();
  @override
  bool existsSync() => real.existsSync();
  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) =>
      real.create(recursive: recursive, exclusive: exclusive);
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => real.writeAsString(
    contents,
    mode: mode,
    encoding: encoding,
    flush: flush,
  );
  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) => real.writeAsBytes(bytes, mode: mode, flush: flush);
  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      real.readAsString(encoding: encoding);
  @override
  Future<Uint8List> readAsBytes() => real.readAsBytes();
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      real.open(mode: mode);
  @override
  Future<File> copy(String newPath) async {
    if (newPath == target) {
      throw const FileSystemException('injected profile publication failure');
    }
    return real.copy(newPath);
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      real.delete(recursive: recursive);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform paths;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('template_transaction_');
    paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
  });
  tearDown(() async {
    PathProviderPlatform.instance = paths;
    await root.delete(recursive: true);
  });
  Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));
  Future<String> prepare(String s, String? key, bool enabled) async =>
      'profile-$s';
  test(
    'T1 real saveFile publication failure restores both prior artifacts',
    () async {
      final p = Profile.normal().copyWith(useGlobalTemplate: true);
      await p.saveFile(bytes('old'), prepare: prepare);
      final profileFile = await p.file;
      final source = await p.templateSourceFile;
      await expectLater(
        IOOverrides.runWithIOOverrides(
          () => p.saveFile(bytes('new'), prepare: prepare),
          _FaultIO(profileFile.path),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await profileFile.readAsString(), 'profile-old');
      expect(await source.readAsString(), 'old');
    },
  );
  test(
    'T1 concurrent real saveFile serializes preparation and publication',
    () async {
      final p = Profile.normal().copyWith(useGlobalTemplate: true);
      final entered = Completer<void>();
      final release = Completer<void>();
      final first = p.saveFile(
        bytes('first'),
        prepare: (s, k, e) async {
          entered.complete();
          await release.future;
          return 'profile-$s';
        },
      );
      await entered.future;
      var secondEntered = false;
      final second = p.saveFile(
        bytes('second'),
        prepare: (s, k, e) async {
          secondEntered = true;
          return 'profile-$s';
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final observedSecond = secondEntered;
      release.complete();
      await Future.wait([first, second]);
      expect(observedSecond, false);
      expect(await (await p.file).readAsString(), 'profile-second');
      expect(await (await p.templateSourceFile).readAsString(), 'second');
    },
  );
  test(
    'T1 queued materialize snapshots latest source and delete is serialized',
    () async {
      final p = Profile.normal().copyWith(useGlobalTemplate: true);
      await p.saveFile(bytes('old'), prepare: prepare);
      final entered = Completer<void>();
      final release = Completer<void>();
      final refresh = p.saveFile(
        bytes('new'),
        prepare: (s, k, e) async {
          entered.complete();
          await release.future;
          return 'profile-$s';
        },
      );
      await entered.future;
      final rebuild = p.materializeTemplate(
        prepare: (s, k, e) async {
          expect(s, 'new');
          return 'profile-$s';
        },
      );
      final deletion = p.deleteArtifacts();
      final pairRead = ProfileArtifacts(
        (await p.file).path,
      ).run((files) => files.read());
      release.complete();
      await Future.wait([refresh, rebuild, deletion]);
      final pair = await pairRead;
      expect(pair.profile, isNull);
      expect(pair.source, isNull);
    },
  );
  test(
    'T1 undo journal recovers interrupted publish before next snapshot',
    () async {
      final p = Profile.normal().copyWith(useGlobalTemplate: true);
      await p.saveFile(bytes('old'), prepare: prepare);
      final file = await p.file;
      final source = await p.templateSourceFile;
      final journal = Directory('${file.path}.transaction');
      await journal.create();
      await File(
        '${journal.path}/profile',
      ).writeAsString('profile-old', flush: true);
      await File('${journal.path}/source').writeAsString('old', flush: true);
      await File('${journal.path}/ready').writeAsString('v1', flush: true);
      await source.writeAsString('interrupted-new');
      final snapshot = await ProfileArtifacts(
        file.path,
      ).run((files) => files.read());
      expect(utf8.decode(snapshot.profile!), 'profile-old');
      expect(utf8.decode(snapshot.source!), 'old');
      expect(journal.existsSync(), false);
    },
  );
  test('T1 OS lock serializes independent isolate snapshots', () async {
    final path = '${root.path}/cross.yaml';
    final entered = Completer<void>();
    final release = Completer<void>();
    final hold = ProfileArtifacts(path).run((files) async {
      entered.complete();
      await release.future;
      await files.publish(bytes('paired-profile'), bytes('paired-source'));
    });
    await entered.future;
    final started = ReceivePort();
    final completed = ReceivePort();
    await Isolate.spawn((List<Object> args) async {
      (args[1] as SendPort).send(true);
      final pair = await ProfileArtifacts(
        args[0] as String,
      ).run((files) => files.read());
      (args[2] as SendPort).send([
        utf8.decode(pair.profile!),
        utf8.decode(pair.source!),
      ]);
    }, <Object>[path, started.sendPort, completed.sendPort]);
    await started.first;
    var done = false;
    final result = completed.first.then((v) {
      done = true;
      return v;
    });
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final premature = done;
    release.complete();
    await hold;
    expect(await result, ['paired-profile', 'paired-source']);
    expect(premature, false);
    started.close();
    completed.close();
  });
}
