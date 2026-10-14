import 'dart:async';
import 'dart:io';

import 'package:fl_clash/core/desktop/launcher.dart';
import 'package:fl_clash/core/desktop/model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';

void main() {
  test(
    'direct child autonomous exit is observable without stopping it',
    () async {
      final logs = <String>[];
      final previous = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      try {
        final exited = Completer<int>();
        final process = _FakeProcess(pid: 42, exitCode: exited.future);
        final launcher = DirectCoreLauncher(
          startProcess: (_, _) async => process,
          corePath: 'FlClashCore',
        );
        await launcher.start(
          sessionId: '0123456789abcdef0123456789abcdef',
          address: 'SECRET_ADDRESS',
        );
        exited.complete(17);
        await pumpEventQueue();
        expect(process.killed, isFalse);
        expect(
          logs,
          contains(
            'Core process exit owner=direct pid=42 exit_code=17 stop_requested=false',
          ),
        );
        expect(logs.join(), isNot(contains('SECRET_ADDRESS')));
      } finally {
        debugPrint = previous;
      }
    },
  );
  test('real Windows owned child exits without a kill request', () async {
    if (!Platform.isWindows) return;
    final logs = <String>[];
    final previous = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
    try {
      final child = await Process.start('cmd.exe', ['/c', 'exit', '17']);
      final lease = DirectCoreLease(
        sessionId: '0123456789abcdef0123456789abcdef',
        process: child,
      );
      expect(await child.exitCode, 17);
      await pumpEventQueue();
      expect(
        logs,
        contains(
          'Core process exit owner=direct pid=${lease.pid} exit_code=17 stop_requested=false',
        ),
      );
    } finally {
      debugPrint = previous;
    }
  });

  test('createCoreSessionId returns lowercase 128-bit hex', () {
    expect(createCoreSessionId(), matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  test('direct lease kills and confirms the owned process exit', () async {
    final process = _FakeProcess(pid: 42, exitCode: Future.value(0));
    String? executable;
    List<String>? arguments;
    final launcher = DirectCoreLauncher(
      startProcess: (value, valueArguments) async {
        executable = value;
        arguments = valueArguments;
        return process;
      },
      corePath: 'FlClashCore',
    );

    final lease = await launcher.start(
      sessionId: '0123456789abcdef0123456789abcdef',
      address: 'test-address',
    );
    final result = await lease.stop(const Duration(seconds: 1));

    expect(lease.owner, CoreProcessOwner.direct);
    expect(lease.pid, 42);
    expect(executable, 'FlClashCore');
    expect(arguments, ['test-address']);
    expect(process.killed, isTrue);
    expect(
      result,
      const CoreProcessStopResult(stopped: true, exitConfirmed: true),
    );
  });

  test('direct lease reports an unconfirmed exit after timeout', () async {
    final process = _FakeProcess(pid: 42, exitCode: Completer<int>().future);
    final launcher = DirectCoreLauncher(
      startProcess: (_, _) async => process,
      corePath: 'FlClashCore',
    );
    final lease = await launcher.start(
      sessionId: '0123456789abcdef0123456789abcdef',
      address: 'test-address',
    );

    final result = await lease.stop(Duration.zero);

    expect(result.stopped, isTrue);
    expect(result.exitConfirmed, isFalse);
  });

  test('direct lease rechecks exit after an unconfirmed timeout', () async {
    final exitCode = Completer<int>();
    final process = _FakeProcess(pid: 42, exitCode: exitCode.future);
    final launcher = DirectCoreLauncher(
      startProcess: (_, _) async => process,
      corePath: 'FlClashCore',
    );
    final lease = await launcher.start(
      sessionId: '0123456789abcdef0123456789abcdef',
      address: 'test-address',
    );

    final firstResult = await lease.stop(Duration.zero);
    exitCode.complete(0);
    final secondResult = await lease.stop(const Duration(seconds: 1));

    expect(firstResult.exitConfirmed, isFalse);
    expect(secondResult.exitConfirmed, isTrue);
  });
}

class _FakeProcess implements Process {
  @override
  final int pid;

  @override
  final Future<int> exitCode;

  @override
  final Stream<List<int>> stdout = const Stream.empty();

  @override
  final Stream<List<int>> stderr = const Stream.empty();

  bool killed = false;

  _FakeProcess({required this.pid, required this.exitCode});

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}
