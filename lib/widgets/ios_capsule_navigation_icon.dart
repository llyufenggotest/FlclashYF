import 'package:fl_clash/common/common.dart';
import 'package:material_ui/material_ui.dart';

enum IOSCapsuleIconKind { dashboard, proxies, profiles, tools }

class IOSCapsuleNavigationIcon extends StatelessWidget {
  const IOSCapsuleNavigationIcon({
    super.key,
    required this.kind,
    required this.selected,
  });

  final IOSCapsuleIconKind kind;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final color = iconTheme.color ?? Theme.of(context).colorScheme.onSurface;
    return AnimatedScale(
      scale: selected ? 1.08 : 1,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutBack,
      child: AnimatedContainer(
        key: selected
            ? ValueKey('capsule-selected-${kind.name}')
            : ValueKey('capsule-${kind.name}'),
        width: 34,
        height: 30,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(AppCorner.md),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.15),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : const [],
        ),
        child: CustomPaint(
          painter: _IOSCapsuleIconPainter(
            kind: kind,
            color: color,
            selected: selected,
          ),
        ),
      ),
    );
  }
}

class _IOSCapsuleIconPainter extends CustomPainter {
  const _IOSCapsuleIconPainter({
    required this.kind,
    required this.color,
    required this.selected,
  });

  final IOSCapsuleIconKind kind;
  final Color color;
  final bool selected;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = selected ? 2.05 : 1.75
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final center = size.center(Offset.zero);
    switch (kind) {
      case IOSCapsuleIconKind.dashboard:
        canvas.drawArc(
          Rect.fromCenter(
            center: center.translate(0, 2),
            width: 20,
            height: 18,
          ),
          3.45,
          2.52,
          false,
          paint,
        );
        canvas.drawLine(center.translate(-7, 7), center.translate(7, 7), paint);
        canvas.drawLine(center.translate(0, 2), center.translate(5, -3), paint);
        canvas.drawCircle(center.translate(0, 2), 1.35, paint);
        return;
      case IOSCapsuleIconKind.proxies:
        final left = center.translate(-7, 4);
        final top = center.translate(0, -6);
        final right = center.translate(7, 4);
        canvas.drawLine(left, top, paint);
        canvas.drawLine(top, right, paint);
        canvas.drawLine(left, right, paint);
        canvas.drawCircle(left, 3, paint);
        canvas.drawCircle(top, 3, paint);
        canvas.drawCircle(right, 3, paint);
        return;
      case IOSCapsuleIconKind.profiles:
        final rect = RRect.fromRectAndRadius(
          Rect.fromCenter(center: center, width: 18, height: 22),
          const Radius.circular(4),
        );
        canvas.drawRRect(rect, paint);
        canvas.drawLine(
          center.translate(-5, -2),
          center.translate(5, -2),
          paint,
        );
        canvas.drawLine(center.translate(-5, 3), center.translate(3, 3), paint);
        canvas.drawLine(center.translate(-5, 8), center.translate(1, 8), paint);
        return;
      case IOSCapsuleIconKind.tools:
        final path = Path()
          ..moveTo(center.dx - 7, center.dy + 7)
          ..lineTo(center.dx + 5, center.dy - 5)
          ..moveTo(center.dx + 2, center.dy - 7)
          ..lineTo(center.dx + 7, center.dy - 2)
          ..moveTo(center.dx - 5, center.dy + 2)
          ..lineTo(center.dx, center.dy + 7);
        canvas.drawPath(path, paint);
        canvas.drawCircle(center.translate(-7, 7), 2.2, paint);
        canvas.drawCircle(center.translate(7, -7), 1.4, paint);
        return;
    }
  }

  @override
  bool shouldRepaint(covariant _IOSCapsuleIconPainter oldDelegate) =>
      oldDelegate.kind != kind ||
      oldDelegate.color != color ||
      oldDelegate.selected != selected;
}
