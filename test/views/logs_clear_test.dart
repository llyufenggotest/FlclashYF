import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:mocktail/mocktail.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/logs.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

class _Core extends Mock implements CoreController {}

void main() {
  for (final size in [const Size(390, 844), const Size(1440, 1000)]) {
    testWidgets(
      'logs page exposes the top clear action at ${size.width}px',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final container = ProviderContainer(
          overrides: [
            viewSizeProvider.overrideWithBuild((_, _) => size),
            patchClashConfigProvider.overrideWithValue(
              const PatchClashConfig(logLevel: LogLevel.debug),
            ),
          ],
        );
        addTearDown(container.dispose);
        globalState.container = container;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const TestApp(child: LogsView()),
          ),
        );
        await tester.pumpAndSettle();
        final l10n = tester.element(find.byType(LogsView)).appLocalizations;
        final clearAction = find.byTooltip(l10n.clear);
        expect(clearAction, findsOneWidget);
        expect(find.byIcon(Icons.delete_sweep_outlined), findsOneWidget);
        final actionRect = tester.getRect(clearAction);
        expect(actionRect.top, lessThan(100));
        expect(actionRect.right, lessThanOrEqualTo(size.width));
        await tester.tap(clearAction);
        await tester.pumpAndSettle();
        expect(find.text(l10n.confirm), findsOneWidget);
      },
    );
  }

  testWidgets('a delayed initial backlog cannot resurrect cleared logs', (
    tester,
  ) async {
    final core = _Core();
    final backlog = Completer<List<Log>>();
    when(() => core.startLogNotify()).thenAnswer((_) => backlog.future);
    when(() => core.stopLogNotify()).thenAnswer((_) async {});
    final container = ProviderContainer(
      overrides: [
        coreHandlerProvider.overrideWithValue(core),
        coreStatusProvider.overrideWithBuild((_, _) => CoreStatus.connected),
        viewSizeProvider.overrideWithBuild((_, _) => const Size(800, 600)),
        patchClashConfigProvider.overrideWithValue(
          const PatchClashConfig(logLevel: LogLevel.debug),
        ),
      ],
    );
    addTearDown(container.dispose);
    globalState.container = container;
    globalState.isBackground.value = false;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TestApp(child: LogsView()),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = tester.element(find.byType(LogsView)).appLocalizations;
    await tester.tap(find.byTooltip(l10n.clear));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.confirm));
    await tester.pumpAndSettle();
    backlog.complete([Log.app('stale backlog')]);
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(container.read(logsProvider).list, isEmpty);
    expect(find.text('stale backlog'), findsNothing);
    container.read(logsProvider.notifier).add(Log.app('live log'));
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(find.text('live log'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'clear confirms, cancels safely and clears paused retained logs',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = ProviderContainer(
        overrides: [
          viewSizeProvider.overrideWithBuild((_, _) => const Size(1400, 1000)),
          patchClashConfigProvider.overrideWithValue(
            const PatchClashConfig(logLevel: LogLevel.debug),
          ),
        ],
      );
      addTearDown(container.dispose);
      globalState.container = container;
      final logs = container.read(logsProvider.notifier);
      logs.add(Log.app('old entry'));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const TestApp(child: LogsView()),
        ),
      );
      await tester.pumpAndSettle();
      final l10n = tester.element(find.byType(LogsView)).appLocalizations;
      await tester.tap(find.byIcon(Icons.pause));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(l10n.clear));
      await tester.pumpAndSettle();
      expect(find.text('old entry'), findsOneWidget);
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
      expect(container.read(logsProvider).list, hasLength(1));
      final revision = container.read(logsProvider).revision;
      await tester.tap(find.byTooltip(l10n.clear));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.confirm));
      await tester.pumpAndSettle();
      expect(container.read(logsProvider).list, isEmpty);
      expect(container.read(logsProvider).revision, greaterThan(revision));
      expect(find.text('old entry'), findsNothing);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      logs.add(Log.app('new entry'));
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(find.text('new entry'), findsOneWidget);
      expect(find.text('old entry'), findsNothing);
    },
  );
}
