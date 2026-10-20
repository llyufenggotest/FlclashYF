// ignore_for_file: avoid_print

import 'dart:convert';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/desktop/rpc_client.dart';
import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/manager/core_manager.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/manager/mobile_manager.dart';
import 'package:fl_clash/core/method.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'helpers/test_app.dart';
import 'helpers/test_profiles.dart';
import 'core/desktop/fakes.dart';
import 'power_repair_test.dart' show RepairWire;
import 'package:fl_clash/core/controller.dart';

class OrderedListener with CoreEventListener {
  final order = <String>[];
  @override
  void onLog(Log log) => order.add(log.payload);
  @override
  void onRequest(TrackerInfo info) => order.add(info.id);
  @override
  void onDns(DnsQuery q) => order.add(q.domain);
  @override
  void onLoaded(String name) => order.add(name);
}

void main() {
  testWidgets('mobile platform wire retains batch through MobileManager', (
    tester,
  ) async {
    final c = ProviderContainer(
      overrides: [
        coreHandlerProvider.overrideWithValue(
          CoreController.scoped(RepairWire()),
        ),
        profilesProvider.overrideWith(TestProfiles.new),
        addedRulesStreamProvider.overrideWith((_, _) => Stream.value([])),
      ],
    );
    globalState.container = c;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const TestApp(
          child: MobileManager(child: CoreManager(child: SizedBox.shrink())),
        ),
      ),
    );
    await tester.pump();
    final listener =
        tester.state(find.byType(MobileManager)) as ServiceListener;
    Service().addListener(listener);
    var publishes = 0;
    final sub = c.listen(logsProvider, (_, _) => publishes++);
    const codec = StandardMethodCodec();
    final payload = jsonEncode(
      CoreMethodCall(
        method: CoreMethod.message,
        arguments: List.generate(
          1000,
          (i) => {
            'type': 'log',
            'data': {'LogLevel': 'info', 'Payload': 'mobile-$i'},
          },
        ),
      ).toJson(),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          '$packageName/service',
          codec.encodeMethodCall(MethodCall('event', payload)),
          null,
        );
    await tester.pump();
    expect(publishes, 4);
    expect(c.read(logsProvider).length, 1000);
    expect(c.read(logsProvider).list.last.payload, 'mobile-999');
    print(
      'REPAIR_JSON ${jsonEncode({'kind': 'mobile_wire_batch_1000', 'publishes': publishes, 'retained': c.read(logsProvider).length})}',
    );
    Service().removeListener(listener);
    sub.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    c.dispose();
    await tester.pump();
  });

  testWidgets(
    'production wire batch bounded provider publication preserves ordered histories',
    (tester) async {
      final c = ProviderContainer(
        overrides: [
          coreHandlerProvider.overrideWithValue(
            CoreController.scoped(RepairWire()),
          ),
          profilesProvider.overrideWith(TestProfiles.new),
          addedRulesStreamProvider.overrideWith((_, _) => Stream.value([])),
          patchClashConfigProvider.overrideWithValue(
            const PatchClashConfig(logLevel: LogLevel.debug),
          ),
        ],
      );
      globalState.container = c;
      globalState.isBackground.value = false;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const TestApp(child: CoreManager(child: SizedBox.shrink())),
        ),
      );
      await tester.pump();
      final transport = FakeDesktopCoreTransport.connected();
      final client = CoreRpcClient(transport);
      final ordered = OrderedListener();
      coreEventManager.addListener(ordered);
      int logs = 0, requests = 0, dns = 0;
      final subs = [
        c.listen(logsProvider, (_, _) => logs++),
        c.listen(requestsProvider, (_, _) => requests++),
        c.listen(dnsQueriesProvider, (_, _) => dns++),
      ];
      Map<String, Object?> log(int i) => {
        'type': 'log',
        'data': {'LogLevel': i == 999 ? 'error' : 'info', 'Payload': 'log-$i'},
      };
      Future<void> wire(List<Object?> events, int expected) async {
        transport.addJson({'method': 'message', 'arguments': events});
        for (var i = 0; i < 30 && ordered.order.length < expected; i++) {
          await tester.pump(const Duration(milliseconds: 10));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        await tester.pump();
        expect(ordered.order.length, expected);
      }

      await wire(List.generate(1000, log), 1000);
      print(
        'REPAIR_JSON ${jsonEncode({'kind': 'wire_batch_1000', 'publishes': logs, 'retained': c.read(logsProvider).length})}',
      );
      expect(logs, lessThanOrEqualTo(4));
      expect(logs, greaterThan(0));
      expect(
        c.read(logsProvider).list.map((l) => l.payload),
        List.generate(1000, (i) => 'log-$i'),
      );
      expect(c.read(logsProvider).list.last.logLevel, LogLevel.error);
      final request = jsonDecode(
        jsonEncode(
          TrackerInfo(
            id: 'request-1',
            start: DateTime.utc(2026),
            metadata: const Metadata(network: 'tcp'),
            chains: const [],
            rule: 'MATCH',
            rulePayload: '',
          ).toJson(),
        ),
      );
      await wire([
        log(1000),
        {'type': 'request', 'data': request},
        {
          'type': 'dns',
          'data': {
            'domain': 'dns-1',
            'type': 'A',
            'time': '2026-01-01T00:00:00Z',
            'error': 'upstream timeout',
          },
        },
        {'type': 'loaded', 'data': 'provider-1'},
        log(1001),
      ], 1005);
      expect(ordered.order.sublist(1000), [
        'log-1000',
        'request-1',
        'dns-1',
        'provider-1',
        'log-1001',
      ]);
      expect(requests, 1);
      expect(dns, 1);
      expect(c.read(dnsQueriesProvider).list.single.error, 'upstream timeout');
      for (var batch = 0; batch < 5; batch++) {
        await wire(
          List.generate(1000, (i) => log(1002 + batch * 1000 + i)),
          2005 + batch * 1000,
        );
      }
      final retained = c.read(logsProvider).list;
      expect(retained.length, maxLogsLength);
      expect(retained.first.payload, 'log-1002');
      expect(retained.last.payload, 'log-6001');
      print(
        'REPAIR_JSON ${jsonEncode({'kind': 'wire_history_capacity', 'input_logs': 6002, 'retained': retained.length, 'first': retained.first.payload, 'last': retained.last.payload, 'publishes': logs})}',
      );
      final extraRequests = List.generate(
        2500,
        (i) => {
          'type': 'request',
          'data': {...request as Map<String, dynamic>, 'id': 'cap-request-$i'},
        },
      );
      await wire(extraRequests, ordered.order.length + extraRequests.length);
      expect(c.read(requestsProvider).length, maxRequestsLength);
      expect(c.read(requestsProvider).list.first.id, 'cap-request-500');
      expect(c.read(requestsProvider).list.last.id, 'cap-request-2499');
      final extraDns = List.generate(
        3500,
        (i) => {
          'type': 'dns',
          'data': {
            'domain': 'cap-dns-$i',
            'type': 'A',
            'time': '2026-01-01T00:00:00Z',
          },
        },
      );
      await wire(extraDns, ordered.order.length + extraDns.length);
      expect(c.read(dnsQueriesProvider).length, maxDnsQueriesLength);
      expect(c.read(dnsQueriesProvider).list.first.domain, 'cap-dns-500');
      expect(c.read(dnsQueriesProvider).list.last.domain, 'cap-dns-3499');
      coreEventManager.removeListener(ordered);
      for (final sub in subs) {
        sub.close();
      }
      await tester.runAsync(() async {
        await client.close();
        await transport.close();
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 6));
      c.dispose();
    },
  );
}
