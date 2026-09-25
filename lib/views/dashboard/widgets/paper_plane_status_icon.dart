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
        gapColor: Theme.of(context).colorScheme.outlineVariant,
        disconnected: disconnected,
      ),
    );
  }
}

class PaperPlaneStatusPainter extends CustomPainter {
  const PaperPlaneStatusPainter({
    required this.color,
    required this.gapColor,
    required this.disconnected,
  });

  final Color color;
  final Color gapColor;
  final bool disconnected;

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / 24;
    final scaleY = size.height / 24;
    canvas.save();
    canvas.scale(scaleX, scaleY);

    final planePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final plane = Path()
      ..moveTo(3, 10)
      ..lineTo(21, 3)
      ..lineTo(14, 21)
      ..lineTo(10, 14)
      ..close()
      ..moveTo(10, 14)
      ..lineTo(21, 3);
    canvas.drawPath(plane, planePaint);

    if (disconnected) {
      final slash = Path()
        ..moveTo(4, 20)
        ..lineTo(20, 4);
      canvas.drawPath(
        slash,
        Paint()
          ..color = gapColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawPath(
        slash,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(PaperPlaneStatusPainter oldDelegate) {
    return color != oldDelegate.color ||
        gapColor != oldDelegate.gapColor ||
        disconnected != oldDelegate.disconnected;
  }
}
