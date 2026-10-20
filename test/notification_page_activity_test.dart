import 'dart:async';
// ignore_for_file: avoid_print

import 'dart:convert';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/pages/home.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/logs.dart';
import 'package:fl_clash/views/connection/requests.dart';
import 'package:fl_clash/views/dns_queries.dart';
import 'package:fl_clash/widgets/inherited.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'helpers/test_app.dart';
import 'power_repair_test.dart' show RepairWire;

class BacklogWire extends RepairWire {
  final pending = <Completer<List<dynamic>>>[];
  @override
  Future<T?> invokeMethod<T>({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  }) {
    if (method.name.startsWith('start')) {
      calls.update(method.name, (v) => v + 1, ifAbsent: () => 1);
      final c = Completer<List<dynamic>>();
      pending.add(c);
      return c.future.then((v) => v as T?);
    }
    return super.invokeMethod(
      method: method,
      arguments: arguments,
      timeout: timeout,
    );
  }
}

void main() {
  testWidgets(
    'real HomePage Logs to dashboard stops offstage notification stream',
    (tester) async {
      final wire = RepairWire();
      final items = [
        NavigationItem(
          icon: const Icon(Icons.home),
          label: PageLabel.dashboard,
          builder: (_) => const SizedBox.shrink(),
        ),
        NavigationItem(
          icon: const Icon(Icons.bug_report),
          label: PageLabel.logs,
          builder: (_) => const LogsView(),
        ),
      ];
      final c = ProviderContainer(
        overrides: [
          coreHandlerProvider.overrideWithValue(CoreController.scoped(wire)),
          currentNavigationItemsStateProvider.overrideWithValue(
            NavigationItemsState(value: items),
          ),
        ],
      );
      globalState.container = c;
      globalState.isBackground.value = false;
      c.read(coreStatusProvider.notifier).value = CoreStatus.connected;
      c.read(viewSizeProvider.notifier).value = const Size(1200, 1000);
      c.read(currentPageLabelProvider.notifier).toPage(PageLabel.logs);
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const TestApp(includeNavigatorKey: false, child: HomePage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(wire.calls['startLogNotify'], 1);
      c.read(currentPageLabelProvider.notifier).toPage(PageLabel.dashboard);
      await tester.pumpAndSettle();
      print(
        'REPAIR_JSON ${jsonEncode({'kind': 'real_navigation', 'calls': wire.calls, 'mounted_logs': find.byType(LogsView, skipOffstage: false).evaluate().length, 'visible_logs': find.byType(LogsView).evaluate().length})}',
      );
      expect(find.byType(LogsView, skipOffstage: false), findsOneWidget);
      expect(find.byType(LogsView), findsNothing);
      expect(wire.calls['stopLogNotify'], 1);
      c.read(currentPageLabelProvider.notifier).toPage(PageLabel.logs);
      await tester.pumpAndSettle();
      expect(wire.calls['startLogNotify'], 2);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      c.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );
  for (final kind in ['Log', 'Request', 'Dns']) {
    testWidgets(
      '$kind active inactive resume stale backlog disposal and stop failure',
      (tester) async {
        final wire = BacklogWire()..failStops = true;
        final c = ProviderContainer(
          overrides: [
            coreHandlerProvider.overrideWithValue(CoreController.scoped(wire)),
          ],
        );
        globalState.container = c;
        globalState.isBackground.value = false;
        c.read(coreStatusProvider.notifier).value = CoreStatus.connected;
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        Widget app(bool active) => UncontrolledProviderScope(
          container: c,
          child: TestApp(
            child: PageActivityScope(
              isActive: active,
              child: kind == 'Log'
                  ? const LogsView()
                  : kind == 'Request'
                  ? const RequestsView()
                  : const DnsQueriesView(),
            ),
          ),
        );
        await tester.pumpWidget(app(false));
        await tester.pump();
        expect(wire.calls['start${kind}Notify'], isNull);
        await tester.pumpWidget(app(true));
        await tester.pump();
        expect(wire.pending.length, 1);
        await tester.pumpWidget(app(false));
        await tester.pump();
        expect(wire.calls['stop${kind}Notify'], 1);
        await tester.pumpWidget(app(true));
        await tester.pump();
        expect(wire.pending.length, 2);
        List<dynamic> backlog(String id) => kind == 'Log'
            ? [
                {'LogLevel': 'info', 'Payload': id, 'dateTime': '2026-01-01'},
              ]
            : kind == 'Request'
            ? [
                jsonDecode(
                  jsonEncode(
                    TrackerInfo(
                      id: id,
                      start: DateTime.utc(2026),
                      metadata: const Metadata(network: 'tcp'),
                      chains: const [],
                      rule: 'MATCH',
                      rulePayload: '',
                    ).toJson(),
                  ),
                ),
              ]
            : [
                {
                  'id': id,
                  'domain': '$id.invalid',
                  'type': 'A',
                  'status': 'success',
                  'time': '2026-01-01T00:00:00Z',
                  'answers': <String>[],
                },
              ];
        wire.pending[0].complete(backlog('stale'));
        wire.pending[1].complete(backlog('fresh'));
        await tester.pump(const Duration(milliseconds: 301));
        final count = kind == 'Log'
            ? c.read(logsProvider).length
            : kind == 'Request'
            ? c.read(requestsProvider).length
            : c.read(dnsQueriesProvider).length;
        expect(
          count,
          1,
          reason: 'old generation must not replay into resumed subscription',
        );
        globalState.isBackground.value = true;
        await tester.pump();
        expect(wire.calls['stop${kind}Notify'], 2);
        globalState.isBackground.value = false;
        await tester.pump();
        expect(wire.calls['start${kind}Notify'], 3);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        wire.pending[2].complete(backlog('disposed'));
        await tester.pump(const Duration(seconds: 1));
        expect(wire.calls['stop${kind}Notify'], 3);
        expect(tester.takeException(), isNull);
        c.dispose();
      },
    );
  }
}
