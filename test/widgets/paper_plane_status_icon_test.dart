// SPDX-License-Identifier: GPL-3.0-or-later
// Vector fixture: NekoBox/SagerNet, Copyright (C) 2021 nekohasekai.
// Source: llyufenggotest/NekoBoxForAndroid-Pskora-Lab@7dcae4569ff1c6adbdead3218bcc6616d089ca76.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fl_clash/views/dashboard/widgets/paper_plane_status_icon.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _connectedPath =
    'M21.25 2.28 L0 12.8 L6.83 15.37 L16.59 7.16 L9.26 15.89 '
    'L17.55 18.56 L21.25 2.29 Z M9.45 17.56 L9.46 22 L12.09 18.41 Z';

Future<Uint8List> _rasterPainter({required bool disconnected}) async {
  final recorder = ui.PictureRecorder();
  PaperPlaneStatusPainter(
    color: Colors.white,
    disconnected: disconnected,
  ).paint(Canvas(recorder), const Size.square(240));
  final picture = recorder.endRecording();
  final image = await picture.toImage(240, 240);
  final bytes = (await image.toByteData())!.buffer.asUint8List();
  image.dispose();
  picture.dispose();
  return bytes;
}

Future<Uint8List> _rasterSvg(String body) async {
  final info = await vg.loadPicture(
    SvgStringLoader(
      '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" '
      'viewBox="0 0 24 24">$body</svg>',
    ),
    null,
  );
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
    ..scale(10)
    ..drawPicture(info.picture);
  final picture = recorder.endRecording();
  final image = await picture.toImage(240, 240);
  final bytes = (await image.toByteData())!.buffer.asUint8List();
  image.dispose();
  picture.dispose();
  info.picture.dispose();
  return bytes;
}

void _expectSamePixels(Uint8List actual, Uint8List expected) {
  var mismatched = 0;
  for (var i = 0; i < actual.length; i += 4) {
    if ((actual[i + 3] - expected[i + 3]).abs() > 20) {
      mismatched++;
    }
  }
  expect(mismatched, lessThan(100), reason: 'vector silhouette pixel mismatch');
}

void main() {
  testWidgets('icon inherits caller foreground and keeps transparent gaps', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: const IconTheme(
            data: IconThemeData(color: Color(0xFF176B34)),
            child: Center(child: PaperPlaneStatusIcon(disconnected: true)),
          ),
        ),
      );
      final customPaint = find.descendant(
        of: find.byType(PaperPlaneStatusIcon),
        matching: find.byType(CustomPaint),
      );
      final painter =
          tester.widget<CustomPaint>(customPaint).painter!
              as PaperPlaneStatusPainter;
      expect(painter.color, const Color(0xFF176B34));
      expect(tester.getSize(customPaint), const Size.square(24));
      expect(painter.disconnected, isTrue);
    }
  });

  test('painter repaints on foreground and connection state changes', () {
    const connected = PaperPlaneStatusPainter(
      color: Colors.white,
      disconnected: false,
    );
    expect(connected.shouldRepaint(connected), isFalse);
    expect(
      connected.shouldRepaint(
        const PaperPlaneStatusPainter(color: Colors.black, disconnected: false),
      ),
      isTrue,
    );
    expect(
      connected.shouldRepaint(
        const PaperPlaneStatusPainter(color: Colors.white, disconnected: true),
      ),
      isTrue,
    );
  });

  testWidgets('connected raster matches NekoBox filled wings and tail', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final actual = await _rasterPainter(disconnected: false);
      final expected = await _rasterSvg(
        '<path fill="white" d="$_connectedPath"/>',
      );
      _expectSamePixels(actual, expected);
      expect(actual[(190 * 240 + 97) * 4 + 3], 255, reason: 'small tail wing');
      const foldPixel = (118 * 240 + 120) * 4 + 3;
      expect(expected[foldPixel], 0, reason: 'fixture fold gap');
      expect(actual[foldPixel], 0, reason: 'fold gap');
    });
  });

  testWidgets('disconnected raster matches holes and descending slash mask', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final actual = await _rasterPainter(disconnected: true);
      final expected = await _rasterSvg(
        '<path fill="white" d="M19.73 22 L21 20.73 L3.27 3 L2 4.27 Z"/>'
        '<defs><clipPath id="mask"><path clip-rule="evenodd" '
        'd="M0 0 H24 V24 H0 Z M4.54 1.73 L3.27 3 L21 20.73 '
        'L22.27 19.46 Z"/></clipPath></defs>'
        '<path clip-path="url(#mask)" fill="white" '
        'd="M17.68 9 L16.09 16 L12.7 14.89 L17.7 8.96 '
        'M10 10.08 L6.43 13.08 L5 12.55 L10 10.08 $_connectedPath"/>',
      );
      _expectSamePixels(actual, expected);
      for (final point in [const Offset(15, 13), const Offset(7, 12)]) {
        final alpha =
            ((point.dy * 10).toInt() * 240 + (point.dx * 10).toInt()) * 4 + 3;
        expect(expected[alpha], 0, reason: 'source cutout $point');
        expect(actual[alpha], 0, reason: 'transparent cutout $point');
      }
      expect(
        actual[(180 * 240 + 167) * 4 + 3],
        255,
        reason: 'descending slash',
      );
      expect(actual[(160 * 240 + 90) * 4 + 3], 0, reason: 'no rising slash');
    });
  });
}
