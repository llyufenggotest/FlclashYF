// Standalone real-IO gate: dart test/common/profile_artifacts_lock_contract.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
// Standalone gate deliberately runs without pub/package resolution, including
// against an immutable baseline tree for the macOS RED assertion.
// ignore: avoid_relative_lib_imports
import '../../lib/common/profile_artifacts.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Uint8List bytes(String value) => Uint8List.fromList(utf8.encode(value));

Future<void> contender(List<Object> args) async {
  final events = args[1] as SendPort;
  final commands = ReceivePort();
  events.send(['ready', commands.sendPort]);
  await commands.first;
  commands.close();
  try {
    for (var i = 0; i < 3; i++) {
      await ProfileArtifacts(args[0] as String).run((files) async {
        final ack = ReceivePort();
        events.send(['enter', ack.sendPort]);
        await ack.first;
        ack.close();
        await Future<void>.delayed(const Duration(milliseconds: 25));
        final value = '${args[2]}-$i';
        await files.publish(bytes(value), bytes(value));
        final pair = await files.read();
        check(
          utf8.decode(pair.profile!) == utf8.decode(pair.source!),
          'unpaired',
        );
        final exitAck = ReceivePort();
        events.send(['exit', exitAck.sendPort]);
        await exitAck.first;
        exitAck.close();
      });
    }
    events.send(['done']);
  } catch (error, stack) {
    events.send(['error', '$error\n$stack']);
  }
}

Future<void> isolates(String path) async {
  final events = ReceivePort();
  final ready = Completer<void>();
  final finished = Completer<void>();
  final gates = <SendPort>[];
  final workers = <Isolate>[];
  var active = 0;
  var maximum = 0;
  var done = 0;
  String? failure;
  final subscription = events.listen((dynamic event) {
    final message = event as List;
    switch (message[0]) {
      case 'ready':
        gates.add(message[1] as SendPort);
        if (gates.length == 8) ready.complete();
      case 'enter':
        active++;
        if (active > maximum) maximum = active;
        (message[1] as SendPort).send(true);
      case 'exit':
        active--;
        (message[1] as SendPort).send(true);
      case 'error':
        failure ??= message[1] as String;
        done++;
        if (done == 8) finished.complete();
      case 'done':
        done++;
        if (done == 8) finished.complete();
    }
  });
  try {
    for (var i = 0; i < 8; i++) {
      workers.add(
        await Isolate.spawn(contender, <Object>[path, events.sendPort, i]),
      );
    }
    await ready.future.timeout(const Duration(seconds: 10));
    for (final gate in gates) {
      gate.send(true);
    }
    await finished.future.timeout(const Duration(seconds: 20));
    check(
      maximum == 1 && active == 0,
      'lockActive maximum=$maximum final=$active',
    );
    check(failure == null, 'worker failed: $failure');
    stdout.writeln(
      'PASS eight-isolate barrier: lockActive<=1 (24 publications)',
    );
  } finally {
    for (final worker in workers) {
      worker.kill(priority: Isolate.immediate);
    }
    await subscription.cancel();
    events.close();
  }
}

Future<void> child(String path, bool crash) async {
  await ProfileArtifacts(path).run((files) async {
    if (crash) {
      await files.publish(bytes('old-profile'), bytes('old-source'));
      final journal = Directory('$path.transaction');
      await journal.create();
      await File(
        '${journal.path}/profile',
      ).writeAsBytes(bytes('old-profile'), flush: true);
      await File(
        '${journal.path}/source',
      ).writeAsBytes(bytes('old-source'), flush: true);
      await File('${journal.path}/ready').writeAsString('v1', flush: true);
      await File(
        files.sourcePath,
      ).writeAsBytes(bytes('interrupted'), flush: true);
      stdout.writeln('held');
      await stdout.flush();
      await Completer<void>().future;
    }
    final sentinel = File('$path.active');
    await sentinel.create(exclusive: true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await files.publish(bytes('$pid'), bytes('$pid'));
    } finally {
      await sentinel.delete();
    }
  });
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == '--child') {
    await child(args[1], args.length > 2);
    return;
  }
  if (args.contains('--require-macos')) {
    check(Platform.isMacOS, 'This gate requires a real macOS Dart runtime');
  }
  stdout.writeln(
    'runtime=${Platform.operatingSystem} dart=${Platform.version}',
  );
  final root = await Directory.systemTemp.createTemp('profile-lock-contract-');
  try {
    await isolates('${root.path}/isolate.yaml');
    if (args.contains('--isolates-only')) return;
    final path = '${root.path}/process.yaml';
    final children = <Process>[];
    for (var i = 0; i < 4; i++) {
      children.add(
        await Process.start(Platform.resolvedExecutable, [
          Platform.script.toFilePath(),
          '--child',
          path,
        ]),
      );
    }
    final outcomes = await Future.wait(
      children.map(
        (process) async => (
          await process.exitCode.timeout(const Duration(seconds: 20)),
          await process.stderr.transform(utf8.decoder).join(),
        ),
      ),
    );
    check(
      outcomes.every((result) => result.$1 == 0),
      'process overlap: $outcomes',
    );
    stdout.writeln('PASS four independent processes');

    // A crashed holder must NOT be guessed dead or have its lock stolen.
    // The test removes it only after its exact child has exited, all contenders
    // have finished, and this fixture has exclusive control of its temp root.
    final crashPath = '${root.path}/crash.yaml';
    final holder = await Process.start(Platform.resolvedExecutable, [
      Platform.script.toFilePath(),
      '--child',
      crashPath,
      '--crash',
    ]);
    try {
      await holder.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 10));
      holder.kill();
      await holder.exitCode.timeout(const Duration(seconds: 10));
      var entered = false;
      var refused = false;
      try {
        await ProfileArtifacts(crashPath)
            .run((_) async {
              entered = true;
            })
            .timeout(const Duration(seconds: 35));
      } on TimeoutException catch (error) {
        refused =
            error.message?.startsWith('Profile artifact lock unavailable:') ??
            false;
      }
      check(refused && !entered, 'abandoned lock must fail closed');
      check(
        await File('$crashPath.isolate-lock').exists(),
        'abandoned marker retained',
      );
      await File('$crashPath.isolate-lock').delete();
      await ProfileArtifacts(crashPath).run((files) async {
        final recovered = await files.read();
        check(utf8.decode(recovered.profile!) == 'old-profile', 'undo profile');
        check(utf8.decode(recovered.source!) == 'old-source', 'undo source');
        await files.publish(bytes('ok'), bytes('ok'));
      });
      check(!await File('$crashPath.isolate-lock').exists(), 'owner release');
      stdout.writeln(
        'PASS crash fail-closed; quiescent fixture removal; owner release',
      );
    } finally {
      holder.kill();
      await holder.exitCode;
    }
  } finally {
    await root.delete(recursive: true);
  }
}
