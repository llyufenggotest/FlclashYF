import 'package:fl_clash/widgets/line_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

LineChartPainter painter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((widget) => widget.painter)
    .whereType<LineChartPainter>()
    .single;

Widget chart(List<Point> points) => MaterialApp(
  home: Center(
    child: SizedBox(
      width: 96,
      height: 36,
      child: LineChart(points: points, color: Colors.blue),
    ),
  ),
);

void main() {
  testWidgets(
    'constant positive production chart stays above zero in tight box',
    (tester) async {
      await tester.pumpWidget(chart(const [Point(0, 8), Point(1, 8)]));
      expect(tester.getSize(find.byType(LineChart)), const Size(96, 36));
      expect(painter(tester).currentRenderPoints.map((point) => point.y), [
        1,
        1,
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'zero positive zero updates immediately without a persistent ticker',
    (tester) async {
      for (final rate in [0.0, 8.0, 0.0]) {
        await tester.pumpWidget(chart([Point(0, rate), Point(1, rate)]));
        final painted = painter(tester);
        expect(painted.currentRenderPoints.map((point) => point.y), [
          rate == 0 ? 0 : 1,
          rate == 0 ? 0 : 1,
        ]);
        expect(
          tester.widget<LineChart>(find.byType(LineChart)).duration,
          Duration.zero,
        );
        if (rate != 0 ||
            painted.prevRenderPoints.any((point) => point.y != 0)) {
          expect(painted.progress, 1);
        }
        expect(tester.binding.transientCallbackCount, 0);
        await tester.pump(const Duration(seconds: 5));
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(tester.takeException(), isNull);
      }
    },
  );

  for (final points in <List<Point>>[
    [],
    [const Point(0, 0)],
    [const Point(1, 3)],
    [const Point(0, 0), const Point(1, 0)],
  ]) {
    testWidgets(
      'finite production painter for ${points.length} points ${points.map((p) => p.y)}',
      (tester) async {
        await tester.pumpWidget(chart(points));
        final rendered = painter(tester).currentRenderPoints;
        expect(rendered.length, points.length);
        expect(
          rendered.every((point) => point.x.isFinite && point.y.isFinite),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
