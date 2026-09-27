import 'dart:io';

import 'package:fl_clash/common/native_log_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
