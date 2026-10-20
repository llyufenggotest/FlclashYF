// ignore_for_file: avoid_print

import 'dart:convert';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/dashboard/widgets/connection_info.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'helpers/test_app.dart';

class RepairWire extends CoreHandlerInterface {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected ${invocation.memberName}');
  final calls = <String, int>{};
  int bytes = 0;
  bool failStops = false;
  @override
  Future<T?> invokeMethod<T>({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  }) async {
    calls.update(method.name, (v) => v + 1, ifAbsent: () => 1);
    Object? result;
    if (method.name == 'getConnectionsCount') {
      result = 1000;
      bytes += utf8.encode(jsonEncode(result)).length;
    } else if (method == CoreMethod.getConnections) {
      final rows = List.generate(
        1000,
        (i) => TrackerInfo(
          id: 'id-$i',
          start: DateTime.utc(2026),
          metadata: const Metadata(
            network: 'tcp',
            host: 'example.invalid',
            destinationPort: '443',
          ),
          chains: const ['test'],
          rule: 'MATCH',
          rulePayload: '',
        ).toJson(),
      );
      result = {'connections': jsonDecode(jsonEncode(rows))};
      bytes += utf8.encode(jsonEncode(rows)).length;
    } else if (method.name.startsWith('start')) {
      result = [];
    } else if (failStops && method.name.startsWith('stop')) {
      throw StateError('stop rejected');
    } else {
      result = true;
    }
    return result as T?;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'default connection card requests scalar count not tracker arrays',
    (tester) async {
      final wire = RepairWire();
      final c = ProviderContainer(
        overrides: [
          coreHandlerProvider.overrideWithValue(CoreController.scoped(wire)),
        ],
      );
      globalState.container = c;
      globalState.isAttach = false;
      c.read(coreStatusProvider.notifier).value = CoreStatus.connected;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const TestApp(child: Scaffold(body: ConnectionInfo())),
        ),
      );
      await tester.pump();
      expect(find.text('1000'), findsOneWidget);
      print(
        'REPAIR_JSON ${jsonEncode({'kind': 'count_card', 'calls': wire.calls, 'bytes': wire.bytes})}',
      );
      expect(wire.calls['getConnections'], isNull);
      expect(wire.calls['getConnectionsCount'], 1);
      expect(wire.bytes, 4);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );
}
