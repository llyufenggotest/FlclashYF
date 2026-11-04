import 'dart:io';

import 'package:fl_clash/common/native_log_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'unreadable cutoff keeps current identity but withholds channel history',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ipad-unreadable-',
      );
      addTearDown(() => directory.delete(recursive: true));
      await Directory('${directory.path}/logs-cleared-at.json').create();
      final exporter = NativeLogExport(
        File('${directory.path}/native.log'),
        runnerDiagnosticReader: () async =>
            '===== iPadDiagnostic-v1 =====\n'
            'runnerLocal=readable sharedSource=unavailable dropped=0\n'
            '{"timestamp":"2026-11-04T00:00:01Z","event":"withheld-secret"}\n',
      );
      final output = await exporter.read();
      expect(output, contains('runnerLocal=readable'));
      expect(output, contains('shared_history=withheld'));
      expect(output, isNot(contains('withheld-secret')));
    },
  );

  for (final corrupt in [false, true]) {
    test('channel sources respect cutoff corrupt=$corrupt', () async {
      final directory = await Directory.systemTemp.createTemp('ipad-cutoff-');
      addTearDown(() => directory.delete(recursive: true));
      final native = File('${directory.path}/ios-necore-native.log');
      String row(String marker, String timestamp) =>
          '{"schema":"iPadDiagnostic-v1","stage":"disconnect","timestamp":"$timestamp","error_code":"$marker"}';
      final history = StringBuffer()
        ..writeln('===== iPadDiagnostic-v1 =====')
        ..writeln(
          'schema=iPadDiagnostic-v1 source_base=de6517d43c3a3277df4f0ce14c42b3f791f9fb05 image_uuid=unavailable os=27.0.1 device_class=ipad bundle_relation=true embedded_profile=true signature_resources=true signing_groups_count=unavailable signing_vpn_entitlement=unavailable',
        )
        ..writeln('runnerLocal=readable sharedSource=readable dropped=0');
      for (final source in ['local', 'pinned', 'NE']) {
        if (source == 'pinned') {
          history.writeln('===== pinned startup window =====');
        } else if (source == 'NE') {
          history.writeln(
            '===== NE shared diagnostic (NE private fallback is not app-readable) =====',
          );
        }
        history
          ..writeln(row('new-$source', '2026-11-04T00:00:01Z'))
          ..writeln(row('old-$source', '2020-01-01T00:00:00Z'))
          ..writeln(row('malformed-$source', 'bad-time'))
          ..writeln('untimestamped-$source');
      }
      final exporter = NativeLogExport(
        native,
        runnerDiagnosticReader: () async => history.toString(),
      );
      await exporter.clear(DateTime.utc(2026, 11, 4));
      if (corrupt) {
        await File('${directory.path}/logs-cleared-at.json').writeAsString('{');
      }
      final output = await exporter.read();
      expect(output, contains('source_base=de6517'));
      expect(output, contains('runnerLocal=readable'));
      expect(output, isNot(contains('old-')));
      expect(output, isNot(contains('malformed-')));
      expect(output, isNot(contains('untimestamped-')));
      for (final source in ['local', 'pinned', 'NE']) {
        expect(output.contains('new-$source'), !corrupt);
      }
      if (corrupt) expect(output, contains('shared_history=withheld'));
    });
  }

  test(
    'channel malformed timestamp never inherits a fresh row even without cutoff',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ipad-malformed-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final exporter = NativeLogExport(
        File('${directory.path}/native.log'),
        runnerDiagnosticReader: () async =>
            '{"timestamp":"2026-11-04T00:00:01Z","event":"fresh"}\n'
            '{"timestamp":"bad-time","event":"malformed-secret"}\n'
            '{"event":"missing-timestamp-secret"}\n',
      );
      expect(await exporter.read(), contains('fresh'));
      expect(await exporter.read(), isNot(contains('secret')));
    },
  );

  test('shared JSON rows cannot inherit timestamp as continuations', () async {
    final directory = await Directory.systemTemp.createTemp('ipad-shared-');
    addTearDown(() => directory.delete(recursive: true));
    final native = File('${directory.path}/ios-necore-native.log');
    final exporter = NativeLogExport(native);
    await exporter.clear(DateTime.utc(2026, 11, 4));
    for (final name in [
      'ios-necore-native.log',
      'ios-switch-Runner.log',
      'ios-switch-NECore.log',
    ]) {
      await File('${directory.path}/$name').writeAsString(
        '{"timestamp":"2026-11-04T00:00:01Z","event":"fresh"}\n'
        '{"timestamp":"bad","event":"old-secret"}\n'
        'old-secret-continuation\n',
      );
    }
    final output = await exporter.read();
    expect(output, contains('fresh'));
    expect(output, isNot(contains('old-secret')));
  });
  test(
    'rotation, missing files, unknown old lines and repeat clears stay cleared',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'native-log-rotate',
      );
      addTearDown(() => directory.delete(recursive: true));
      final native = File('${directory.path}/ios-necore-native.log');
      final exporter = NativeLogExport(native);
      await exporter.clear(DateTime.parse('2026-09-27T12:00:00.500Z'));
      expect(await exporter.read(), contains('(not recorded)'));
      await native.writeAsString(
        'old unparseable line\n'
        '2026-09-27T12:00:00Z same second is old\n'
        'old continuation\n'
        '2026-09-27T12:00:01Z new native\n'
        'new continuation\n',
      );
      final exported = await exporter.read();
      expect(exported, isNot(contains('old')));
      expect(exported, contains('new continuation'));
      await exporter.clear(DateTime.parse('2026-09-27T12:00:02Z'));
      expect(
        await NativeLogExport(native).read(),
        isNot(contains('new native')),
      );
      await native.writeAsString('2026-09-27T12:00:03Z rotated new\n');
      expect(await NativeLogExport(native).read(), contains('rotated new'));
    },
  );

  test(
    'corrupt cutoff fails closed rather than exporting cleared history',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'native-log-corrupt',
      );
      addTearDown(() => directory.delete(recursive: true));
      final native = File('${directory.path}/ios-necore-native.log');
      await native.writeAsString('old content');
      await File('${directory.path}/logs-cleared-at.json').writeAsString('{');
      await expectLater(NativeLogExport(native).read(), throwsFormatException);
    },
  );

  test(
    'unexpected cutoff JSON type fails closed with a format error',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'native-log-cutoff-type',
      );
      addTearDown(() => directory.delete(recursive: true));
      final native = File('${directory.path}/ios-necore-native.log');
      await native.writeAsString('2026-09-27T12:00:01Z diagnostic\n');
      await File(
        '${directory.path}/logs-cleared-at.json',
      ).writeAsString('{"cutoff":12}');

      await expectLater(
        NativeLogExport(native).readEntries(),
        throwsFormatException,
      );
    },
  );

  test(
    'clear persists a cutoff for all native exports without altering files',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'native-log-clear',
      );
      addTearDown(() => directory.delete(recursive: true));
      final native = File('${directory.path}/ios-necore-native.log');
      final runner = File('${directory.path}/ios-switch-Runner.log');
      final extension = File('${directory.path}/ios-switch-NECore.log');
      const nativeOld = '2026-09-27T12:00:00Z [NECore] old native\n';
      const runnerOld =
          '{"timestamp":"2026-09-27T12:00:00.100Z","event":"old runner"}\n';
      const extensionOld =
          '{"timestamp":"2026-09-27T12:00:00.200Z","event":"old extension"}\n';
      await native.writeAsString(nativeOld);
      await runner.writeAsString(runnerOld);
      await extension.writeAsString(extensionOld);
      final exporter = NativeLogExport(native);
      expect(await exporter.read(), contains('old native'));
      await exporter.clear(DateTime.parse('2026-09-27T12:00:00.500Z'));
      expect(await native.readAsString(), nativeOld);
      expect(await runner.readAsString(), runnerOld);
      expect(await extension.readAsString(), extensionOld);
      await native.writeAsString(
        '2026-09-27T12:00:01Z [NECore] new native\n',
        mode: FileMode.append,
      );
      await runner.writeAsString(
        '{"timestamp":"2026-09-27T12:00:00.501Z","event":"new runner"}\n',
        mode: FileMode.append,
      );
      await extension.writeAsString(
        '{"timestamp":"2026-09-27T12:00:01Z","event":"new extension"}\n',
        mode: FileMode.append,
      );
      final exported = await NativeLogExport(native).read();
      expect(exported, isNot(contains('old')));
      expect(exported, contains('new native'));
      expect(exported, contains('new runner'));
      expect(exported, contains('new extension'));
    },
  );

  test(
    'readEntries restores only the newest persisted diagnostic lines',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'native-log-entries',
      );
      addTearDown(() => directory.delete(recursive: true));
      final native = File('${directory.path}/ios-necore-native.log');
      final runner = File('${directory.path}/ios-switch-Runner.log');
      await native.writeAsString(
        '2026-09-27T12:00:00Z old native\n'
        '2026-09-27T12:00:02Z newest native\n',
      );
      await runner.writeAsString(
        '{"timestamp":"2026-09-27T12:00:01Z","event":"app_background"}\n',
      );
      final exporter = NativeLogExport(native);
      await exporter.clear(DateTime.parse('2026-09-27T12:00:00.500Z'));

      final entries = await exporter.readEntries(maxLines: 2);

      expect(entries, hasLength(2));
      expect(entries.first, contains('app_background'));
      expect(entries.last, contains('newest native'));
      expect(entries.join(), isNot(contains('old native')));
    },
  );
}
