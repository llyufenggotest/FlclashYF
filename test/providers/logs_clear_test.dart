import 'dart:io';

import 'package:fl_clash/common/native_log_export.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _NativeLogs extends Logs {
  final NativeLogExport exporter;

  _NativeLogs(this.exporter);

  @override
  Future<NativeLogExport?> get nativeLogExport async => exporter;
}

void main() {
  test(
    'provider clear persists native cutoff and advances every revision',
    () async {
      final directory = await Directory.systemTemp.createTemp('logs-provider');
      addTearDown(() => directory.delete(recursive: true));
      final native = File('${directory.path}/ios-necore-native.log');
      await native.writeAsString('2020-01-01T00:00:00Z old native\n');
      final container = ProviderContainer(
        overrides: [
          logsProvider.overrideWith(() => _NativeLogs(NativeLogExport(native))),
          patchClashConfigProvider.overrideWithValue(
            const PatchClashConfig(logLevel: LogLevel.debug),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(logsProvider.notifier);
      notifier.add(Log.app('old'));
      var revision = container.read(logsProvider).revision;
      await notifier.clearLogs();
      expect(container.read(logsProvider).list, isEmpty);
      expect(container.read(logsProvider).revision, greaterThan(revision));
      expect(
        await NativeLogExport(native).read(),
        isNot(contains('old native')),
      );
      revision = container.read(logsProvider).revision;
      notifier.add(Log.app('new'));
      expect(container.read(logsProvider).revision, greaterThan(revision));
      expect(container.read(logsProvider).list.single.payload, 'new');
      revision = container.read(logsProvider).revision;
      await notifier.clearLogs();
      expect(container.read(logsProvider).revision, greaterThan(revision));
      expect(await native.readAsString(), contains('old native'));
    },
  );

  test('native cutoff write failure leaves visible logs intact', () async {
    final directory = await Directory.systemTemp.createTemp('logs-failure');
    addTearDown(() => directory.delete(recursive: true));
    await Directory('${directory.path}/logs-cleared-at.json.tmp').create();
    final container = ProviderContainer(
      overrides: [
        logsProvider.overrideWith(
          () => _NativeLogs(
            NativeLogExport(File('${directory.path}/ios-necore-native.log')),
          ),
        ),
        patchClashConfigProvider.overrideWithValue(const PatchClashConfig()),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(logsProvider.notifier);
    notifier.add(Log.app('retained'));
    await expectLater(
      notifier.clearLogs(),
      throwsA(isA<FileSystemException>()),
    );
    expect(container.read(logsProvider).list.single.payload, 'retained');
    expect(notifier.hasCleared, isFalse);
  });
}
