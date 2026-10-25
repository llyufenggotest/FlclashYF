import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/views/dashboard/widgets/network_speed.dart';
import 'package:fl_clash/widgets/inherited.dart';
import 'package:fl_clash/widgets/line_chart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';
import 'line_chart_zero_baseline_test.dart' show painter;

Widget app(
  ProviderContainer container, {
  List<Traffic>? traffics,
  bool active = true,
}) => UncontrolledProviderScope(
  container: container,
  child: TestApp(
    homeBuilder: (child) => Scaffold(
      body: Center(child: SizedBox(width: 320, child: child)),
    ),
    child: PageActivityScope(
      isActive: active,
      child: TickerMode(
        enabled: active,
        child: Offstage(
          offstage: !active,
          child: NetworkSpeed(traffics: traffics),
        ),
      ),
    ),
  ),
);

void main() {
  for (final count in [0, 1, 29, 30, 31]) {
    testWidgets(
      'production speed chart keeps latest 30 finite points input=$count',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final samples = List.generate(
          count,
          (index) => Traffic(up: index + 1, down: index + 2),
        );
        await tester.pumpWidget(app(container, traffics: samples));
        final widget = tester.widget<LineChart>(find.byType(LineChart));
        final expected = samples
            .skip(count > 30 ? count - 30 : 0)
            .map((sample) => sample.speed.toDouble())
            .toList();
        expect(widget.points.length, 30);
        expect(
          widget.points.map((point) => point.x),
          List.generate(30, (index) => index.toDouble()),
        );
        expect(widget.points.map((point) => point.y), [
          ...List.filled(30 - expected.length, 0.0),
          ...expected,
        ]);
        expect(
          painter(tester).currentRenderPoints.every(
            (point) => point.x.isFinite && point.y.isFinite,
          ),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'compact bidirectional rates and repaint boundary survive zero positive zero',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      for (final sample in [
        const Traffic(),
        const Traffic(up: 1024, down: 2048),
        const Traffic(),
      ]) {
        await tester.pumpWidget(
          app(container, traffics: List.filled(30, sample)),
        );
        final chartFinder = find.byType(LineChart);
        expect(tester.getSize(chartFinder), const Size(96, 36));
        expect(tester.widget<LineChart>(chartFinder).duration, Duration.zero);
        expect(
          find.ancestor(
            of: chartFinder,
            matching: find.byType(RepaintBoundary),
          ),
          findsWidgets,
        );
        expect(find.text('↑'), findsOneWidget);
        expect(find.text('↓'), findsOneWidget);
        expect(
          tester.getCenter(find.text('↑')).dx,
          lessThan(tester.getCenter(find.text('↓')).dx),
        );
        for (final rate in {sample.up, sample.down}) {
          expect(
            find.text('${rate.traffic.show}/s'),
            findsNWidgets(sample.up == sample.down ? 2 : 1),
          );
        }
        expect(
          painter(tester).currentRenderPoints.every(
            (point) => point.y == (sample.speed == 0 ? 0 : 1),
          ),
          isTrue,
        );
        expect(tester.binding.transientCallbackCount, 0);
        await tester.pump(const Duration(seconds: 5));
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'mounted hidden background chart adds no provider samples or recurring frames',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(trafficsProvider.notifier)
          .addTraffic(const Traffic(up: 1024, down: 2048));
      final before = container.read(trafficsProvider);
      var changes = 0;
      final subscription = container.listen(
        trafficsProvider,
        (_, _) => changes++,
      );
      addTearDown(subscription.close);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(app(container));
      expect(
        tester.widget<LineChart>(find.byType(LineChart)).points.last.y,
        3072,
      );
      await tester.pumpWidget(app(container, active: false));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 30));
      expect(find.byType(NetworkSpeed, skipOffstage: false), findsOneWidget);
      expect(container.read(trafficsProvider), same(before));
      expect(changes, 0);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
