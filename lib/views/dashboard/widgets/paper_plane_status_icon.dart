// SPDX-License-Identifier: GPL-3.0-or-later
// Vectors adapted from NekoBox/SagerNet, Copyright (C) 2021 nekohasekai.
// Source: llyufenggotest/NekoBoxForAndroid-Pskora-Lab@7dcae4569ff1c6adbdead3218bcc6616d089ca76.
import 'package:material_ui/material_ui.dart';

class PaperPlaneStatusIcon extends StatelessWidget {
  const PaperPlaneStatusIcon({super.key, required this.disconnected});

  final bool disconnected;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size.square(24),
      painter: PaperPlaneStatusPainter(
        color:
            IconTheme.of(context).color ??
            Theme.of(context).colorScheme.onSurface,
        disconnected: disconnected,
      ),
    );
  }
}

class PaperPlaneStatusPainter extends CustomPainter {
  const PaperPlaneStatusPainter({
    required this.color,
    required this.disconnected,
  });

  final Color color;
  final bool disconnected;

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / 24;
    final scaleY = size.height / 24;
    canvas.save();
    canvas.scale(scaleX, scaleY);

    final planePaint = Paint()..color = color;
    final plane = Path()
      ..moveTo(21.25, 2.28)
      ..lineTo(0, 12.8)
      ..lineTo(6.83, 15.37)
      ..lineTo(16.59, 7.16)
      ..lineTo(9.26, 15.89)
      ..lineTo(17.55, 18.56)
      ..lineTo(21.25, 2.29)
      ..close()
      ..moveTo(9.45, 17.56)
      ..lineTo(9.46, 22)
      ..lineTo(12.09, 18.41)
      ..close();
    if (disconnected) {
      final holes = Path()
        ..moveTo(17.68, 9)
        ..lineTo(16.09, 16)
        ..lineTo(12.7, 14.89)
        ..lineTo(17.7, 8.96)
        ..close()
        ..moveTo(10, 10.08)
        ..lineTo(6.43, 13.08)
        ..lineTo(5, 12.55)
        ..close();
      final gap = Path()
        ..moveTo(4.54, 1.73)
        ..lineTo(3.27, 3)
        ..lineTo(21, 20.73)
        ..lineTo(22.27, 19.46)
        ..close();
      canvas.drawPath(
        Path.combine(
          PathOperation.difference,
          Path.combine(PathOperation.difference, plane, holes),
          gap,
        ),
        planePaint,
      );
      final slash = Path()
        ..moveTo(19.73, 22)
        ..lineTo(21, 20.73)
        ..lineTo(3.27, 3)
        ..lineTo(2, 4.27)
        ..close();
      canvas.drawPath(slash, planePaint);
    } else {
      canvas.drawPath(plane, planePaint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(PaperPlaneStatusPainter oldDelegate) {
    return color != oldDelegate.color ||
        disconnected != oldDelegate.disconnected;
  }
}
