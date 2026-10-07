import 'dart:async';

import 'package:fl_clash/core/desktop/lifecycle.dart';
import 'package:fl_clash/core/desktop/model.dart';
import 'package:fl_clash/core/desktop/rpc_client.dart';
import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/core/service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_test/flutter_test.dart';

final class _MockLifecycle extends Mock
    implements DesktopCoreLifecycleController {}

final class _MockRpcClient extends Mock implements CoreRpcChannel {}

void main() {
  late _MockLifecycle lifecycle;
  late _MockRpcClient rpcClient;
  late StreamController<DesktopCoreFailure> crashes;
  late CoreService service;

  const result = CoreLifecycleResult(
    revision: 1,
    outcome: CoreLifecycleOutcome.applied,
  );

  setUp(() async {
    await CoreService.resetInstance();
    lifecycle = _MockLifecycle();
    rpcClient = _MockRpcClient();
    crashes = StreamController<DesktopCoreFailure>.broadcast();
    when(() => lifecycle.crashEvents).thenAnswer((_) => crashes.stream);
    when(() => lifecycle.start()).thenAnswer((_) async => result);
    when(() => lifecycle.restart()).thenAnswer((_) async => result);
    when(() => lifecycle.stop()).thenAnswer((_) async => result);
    when(() => lifecycle.close()).thenAnswer((_) async => result);
    when(() => rpcClient.close()).thenAnswer((_) async {});
    service = CoreService.forTesting(
      lifecycle: lifecycle,
      rpcClient: rpcClient,
      installAsSingleton: true,
    );
  });

  tearDown(() async {
    await service.close();
    await CoreService.resetInstance();
    await crashes.close();
  });

  test(
    'delegates lifecycle commands without owning platform details',
    () async {
      expect(await service.start(), same(result));
      expect(await service.restart(), same(result));
      expect(await service.stop(), same(result));

      verify(() => lifecycle.start()).called(1);
      verify(() => lifecycle.restart()).called(1);
      verify(() => lifecycle.stop()).called(1);
    },
  );

  test('delegates Core method calls to the RPC channel', () async {
    when(
      () => rpcClient.invoke<bool>(
        method: CoreMethod.getIsInit,
        arguments: null,
        timeout: null,
      ),
    ).thenAnswer((_) async => true);

    expect(
      await service.invokeMethod<bool>(method: CoreMethod.getIsInit),
      isTrue,
    );
  });

  test('forwards lifecycle crash events once', () async {
    final listener = _CrashListener();
    coreEventManager.addListener(listener);

    crashes.add(
      const DesktopCoreFailure(
        code: 'unexpected_disconnect',
        phase: DesktopCorePhase.running,
        revision: 2,
      ),
    );
    await pumpEventQueue();

    expect(listener.messages, ['core done']);
    coreEventManager.removeListener(listener);
  });

  test(
    'resetInstance closes the retired singleton without replacing it',
    () async {
      final dynamic resetting = Function.apply(CoreService.resetInstance, []);
      expect(resetting, isA<Future<void>>());
      await resetting;

      verify(() => lifecycle.close()).called(1);
      verify(() => rpcClient.close()).called(1);
    },
  );

  test('forTesting does not silently replace an installed singleton', () async {
    final otherLifecycle = _MockLifecycle();
    final otherRpc = _MockRpcClient();
    when(() => otherLifecycle.crashEvents).thenAnswer((_) => crashes.stream);
    when(() => otherLifecycle.close()).thenAnswer((_) async => result);
    when(() => otherRpc.close()).thenAnswer((_) async {});
    final other = CoreService.forTesting(
      lifecycle: otherLifecycle,
      rpcClient: otherRpc,
    );
    try {
      expect(CoreService(), same(service));
    } finally {
      await other.close();
    }
  });

  test('reset awaits RPC cleanup and detaches crash forwarding', () async {
    final lifecycleClose = Completer<CoreLifecycleResult>();
    final rpcClose = Completer<void>();
    when(() => lifecycle.close()).thenAnswer((_) => lifecycleClose.future);
    when(() => rpcClient.close()).thenAnswer((_) => rpcClose.future);
    var finished = false;
    final resetting = CoreService.resetInstance().then((_) => finished = true);
    await pumpEventQueue();
    expect(finished, isFalse);
    lifecycleClose.complete(result);
    await pumpEventQueue();
    expect(finished, isFalse);
    rpcClose.complete();
    await resetting;
    expect(crashes.hasListener, isFalse);
    verify(() => lifecycle.close()).called(1);
    verify(() => rpcClient.close()).called(1);
  });

  test('explicit installation rejects replacing a live singleton', () {
    expect(
      () => CoreService.forTesting(
        lifecycle: lifecycle,
        rpcClient: rpcClient,
        installAsSingleton: true,
      ),
      throwsStateError,
    );
    expect(CoreService(), same(service));
  });

  test('close coalesces lifecycle and RPC cleanup', () async {
    final first = service.close();
    final second = service.close();

    expect(await first, same(result));
    expect(await second, same(result));
    verify(() => rpcClient.beginShutdown()).called(1);
    verify(() => lifecycle.close()).called(1);
    verify(() => rpcClient.close()).called(1);
  });

  test('close keeps RPC subscriptions until Core shutdown finishes', () async {
    final lifecycleClose = Completer<CoreLifecycleResult>();
    when(() => lifecycle.close()).thenAnswer((_) => lifecycleClose.future);

    final closing = service.close();
    await pumpEventQueue();

    verify(() => rpcClient.beginShutdown()).called(1);
    verify(() => lifecycle.close()).called(1);
    verifyNever(() => rpcClient.close());

    lifecycleClose.complete(result);
    expect(await closing, same(result));
    verify(() => rpcClient.close()).called(1);
  });
}

final class _CrashListener with CoreEventListener {
  final List<String> messages = [];

  @override
  void onCrash(String message) {
    messages.add(message);
  }
}
