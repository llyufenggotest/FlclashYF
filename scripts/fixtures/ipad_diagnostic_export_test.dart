import 'dart:io';
import 'package:fl_clash/common/native_log_export.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Runner channel proof survives missing shared directory and cutoff',
    () async {
      var calls = 0;
      const channel = MethodChannel('cc.llyufeng.flclash.dev/service');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'exportIPadDiagnostics');
            calls++;
            return '===== iPadDiagnostic-v1 =====\n'
                'runnerLocal=readable sharedSource=unavailable dropped=0\n'
                '{"schema":"iPadDiagnostic-v1","stage":"tunnel_start_disconnect_error","timestamp":"2026-11-04T00:00:01Z","provider_stage":"rpc_publication","observation":"provider_entry_proved"}\n';
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final exporter = NativeLogExport(
        File('Z:/ipad-diagnostic-unavailable/no-shared/ios-necore-native.log'),
        runnerDiagnosticReader: () =>
            channel.invokeMethod<String>('exportIPadDiagnostics'),
      );
      final text = await exporter.read();
      expect(calls, 1);
      expect(
        text,
        contains('"provider_stage":"rpc_publication"'),
        reason: 'provider_stage=rpc_publication must survive nil shared group',
      );
      expect(text, contains('runnerLocal=readable'));
      expect(text, contains('source=unavailable_or_absent'));
    },
  );
}
