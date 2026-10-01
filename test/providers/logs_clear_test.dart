import 'dart:async';
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

class _ThrowingExporter extends NativeLogExport {
  _ThrowingExporter(super.nativeFile);

  @override
  Future<List<String>> readEntries({int maxLines = 200}) {
    throw const FileSystemException('App Group unavailable');
  }
}

class _DelayedExporter extends NativeLogExport {
  _DelayedExporter(super.nativeFile, this.entries);

  final Future<List<String>> entries;

  @override
  Future<List<String>> readEntries({int maxLines = 200}) => entries;
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
  });

  test('persisted iOS diagnostics repopulate a recreated log buffer', () async {
    final directory = await Directory.systemTemp.createTemp('logs-restore');
    addTearDown(() => directory.delete(recursive: true));
    final native = File('${directory.path}/ios-necore-native.log');
    await native.writeAsString(
      '2026-09-27T12:00:01Z [NECore] tunnel remained active\n',
    );
    final container = ProviderContainer(
      overrides: [
        logsProvider.overrideWith(() => _NativeLogs(NativeLogExport(native))),
        patchClashConfigProvider.overrideWithValue(const PatchClashConfig()),
      ],
    );
    addTearDown(container.dispose);

    await container.read(logsProvider.notifier).restoreNativeDiagnostics();

    final logs = container.read(logsProvider).list;
    expect(logs, hasLength(1));
    expect(logs.single.logLevel, LogLevel.warning);
    expect(logs.single.payload, contains('tunnel remained active'));

    await container.read(logsProvider.notifier).restoreNativeDiagnostics();
    expect(container.read(logsProvider).list, hasLength(1));
  });

  test('native diagnostic read failure does not break the logs page', () async {
    final container = ProviderContainer(
      overrides: [
        logsProvider.overrideWith(
          () => _NativeLogs(_ThrowingExporter(File('/unavailable/native.log'))),
        ),
        patchClashConfigProvider.overrideWithValue(const PatchClashConfig()),
      ],
    );
    addTearDown(container.dispose);

    await expectLater(
      container.read(logsProvider.notifier).restoreNativeDiagnostics(),
      completes,
    );
    expect(container.read(logsProvider).list, isEmpty);
  });

  test(
    'persisted diagnostics bypass the volatile Core log threshold',
    () async {
      final directory = await Directory.systemTemp.createTemp('logs-threshold');
      addTearDown(() => directory.delete(recursive: true));
      final native = File('${directory.path}/ios-necore-native.log');
      await native.writeAsString('2026-09-27T12:00:01Z runner relaunched\n');
      final container = ProviderContainer(
        overrides: [
          logsProvider.overrideWith(() => _NativeLogs(NativeLogExport(native))),
          patchClashConfigProvider.overrideWithValue(
            const PatchClashConfig(logLevel: LogLevel.error),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(logsProvider.notifier).restoreNativeDiagnostics();

      expect(
        container.read(logsProvider).list.single.payload,
        contains('relaunch'),
      );
    },
  );

  test('clear fences an in-flight persisted diagnostic restore', () async {
    final completer = Completer<List<String>>();
    final directory = await Directory.systemTemp.createTemp('logs-race');
    addTearDown(() => directory.delete(recursive: true));
    final container = ProviderContainer(
      overrides: [
        logsProvider.overrideWith(
          () => _NativeLogs(
            _DelayedExporter(
              File('${directory.path}/ios-necore-native.log'),
              completer.future,
            ),
          ),
        ),
        patchClashConfigProvider.overrideWithValue(const PatchClashConfig()),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(logsProvider.notifier);
    final restore = notifier.restoreNativeDiagnostics();

    await notifier.clearLogs();
    completer.complete(['2026-09-27T12:00:01Z stale diagnostic']);
    await restore;

    expect(container.read(logsProvider).list, isEmpty);
  });
}
