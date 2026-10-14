import 'dart:async';

import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/desktop/model.dart';
import 'package:fl_clash/core/desktop/rpc_client.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/logs.dart';
import 'package:fl_clash/views/connection/requests.dart';
import 'package:fl_clash/views/dns_queries.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_app.dart';

import 'fakes.dart';

class _RpcCore extends CoreHandlerInterface {
  final CoreRpcClient client;
  _RpcCore(this.client);

  @override
  Future<T?> invokeMethod<T>({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  }) =>
      client.invoke<T>(method: method, arguments: arguments, timeout: timeout);

  @override
  Future<CoreLifecycleResult> start() => throw UnimplementedError();
  @override
  Future<CoreLifecycleResult> restart() => throw UnimplementedError();
  @override
  Future<CoreLifecycleResult> stop() => throw UnimplementedError();
  @override
  Future<CoreLifecycleResult> close() => throw UnimplementedError();
}

Future<List<Object>> _zoneErrors(Future<void> Function() task) async {
  final errors = <Object>[];
  final done = Completer<void>();
  unawaited(
    runZonedGuarded(() async {
      try {
        await task();
        await pumpEventQueue();
      } finally {
        done.complete();
      }
    }, (error, stack) => errors.add(error)),
  );
  await done.future;
  return errors;
}

void main() {
  for (final method in [
    CoreMethod.stopLogNotify,
    CoreMethod.stopRequestNotify,
    CoreMethod.stopDnsNotify,
  ]) {
    test(
      '${method.name} awaited handler still reports structured failure',
      () async {
        final transport = FakeDesktopCoreTransport.connected();
        final client = CoreRpcClient(transport);
        final handler = _RpcCore(client);
        addTearDown(transport.close);
        addTearDown(client.close);
        transport.disconnect(1);
        await pumpEventQueue();
        final call = switch (method) {
          CoreMethod.stopLogNotify => handler.stopLogNotify,
          CoreMethod.stopRequestNotify => handler.stopRequestNotify,
          _ => handler.stopDnsNotify,
        };
        await expectLater(
          call(),
          throwsA(
            isA<CoreMethodException>().having(
              (e) => e.code,
              'code',
              'transport_disconnected',
            ),
          ),
        );
      },
    );
  }

  test('shutdown wins over remembered disconnect', () async {
    final transport = FakeDesktopCoreTransport.connected();
    final client = CoreRpcClient(transport);
    addTearDown(transport.close);
    addTearDown(client.close);
    transport.disconnect(1);
    await pumpEventQueue();
    client.beginShutdown();
    expect(await client.invoke<bool>(method: CoreMethod.stopLogNotify), isNull);
    expect(transport.sentMessages, isEmpty);
    expect(client.pendingCount, 0);
  });

  test(
    'notification consumer preserves synchronous platform contract',
    () async {
      var calls = 0;
      await consumeNotificationFailure(() {
        calls++;
      });
      expect(calls, 1);
    },
  );

  for (final error in <Object>[
    StateError('programming failure'),
    const CoreMethodException(
      code: 'core_error',
      message: 'Core rejected notification',
    ),
  ]) {
    test(
      'unexpected ${error.runtimeType} still reaches fire-and-forget zone',
      () async {
        final errors = await _zoneErrors(() async {
          unawaited(
            consumeNotificationFailure(() => Future<void>.error(error)),
          );
        });
        expect(errors, [same(error)]);
      },
    );
  }

  for (final start in ['log', 'request', 'dns']) {
    test('$start awaited start still reports transport failure', () async {
      final transport = FakeDesktopCoreTransport.connected();
      final client = CoreRpcClient(transport);
      final core = CoreController.scoped(_RpcCore(client));
      addTearDown(transport.close);
      addTearDown(client.close);
      transport.fail(StateError('synthetic'));
      await pumpEventQueue();
      final invocation = switch (start) {
        'log' => core.startLogNotify(),
        'request' => core.startRequestNotify(),
        _ => core.startDnsNotify(),
      };
      await expectLater(
        invocation,
        throwsA(
          isA<CoreMethodException>().having(
            (e) => e.code,
            'code',
            'transport_error',
          ),
        ),
      );
    });
  }

  for (final failure in ['disconnect', 'failure']) {
    for (final notification in ['log', 'request', 'dns']) {
      test('$notification stop after $failure has no uncaught error', () async {
        final errors = await _zoneErrors(() async {
          final transport = FakeDesktopCoreTransport.connected();
          final client = CoreRpcClient(transport);
          final core = CoreController.scoped(_RpcCore(client));
          try {
            if (failure == 'disconnect') {
              transport.disconnect(1);
            } else {
              transport.fail(StateError('synthetic pipe failure'));
            }
            await pumpEventQueue();
            switch (notification) {
              case 'log':
                core.stopLogNotify();
              case 'request':
                core.stopRequestNotify();
              case 'dns':
                core.stopDnsNotify();
            }
            await pumpEventQueue();
            expect(client.pendingCount, 0);
            expect(transport.sentMessages, isEmpty);
          } finally {
            await client.close();
            await transport.close();
          }
        });
        expect(errors, isEmpty);
      });
    }
  }

  for (final view in <String, Widget>{
    'log': const LogsView(),
    'request': const RequestsView(),
    'dns': const DnsQueriesView(),
  }.entries) {
    testWidgets('${view.key} start race after disconnect is consumed', (
      tester,
    ) async {
      final transport = FakeDesktopCoreTransport.connected();
      final client = CoreRpcClient(transport);
      final core = CoreController.scoped(_RpcCore(client));
      final container = ProviderContainer(
        overrides: [
          coreHandlerProvider.overrideWithValue(core),
          coreStatusProvider.overrideWithBuild((_, _) => CoreStatus.connected),
          viewSizeProvider.overrideWithBuild((_, _) => const Size(1400, 1000)),
          patchClashConfigProvider.overrideWithValue(
            const PatchClashConfig(logLevel: LogLevel.debug),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(transport.close);
      addTearDown(client.close);
      globalState.container = container;
      globalState.isBackground.value = false;
      transport.disconnect(1);
      await tester.runAsync(() => pumpEventQueue());
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: TestApp(child: view.value),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(transport.sentMessages, isEmpty);
      expect(client.pendingCount, 0);
    });
  }
}
