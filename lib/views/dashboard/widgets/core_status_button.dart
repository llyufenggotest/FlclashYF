// SPDX-License-Identifier: GPL-3.0-or-later
// Ring/colors adapted from NekoBox/SagerNet (nekohasekai, 2021), revision 7dcae4569ff1c6adbdead3218bcc6616d089ca76.
import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'paper_plane_status_icon.dart';

export 'paper_plane_status_icon.dart';

class ConnectedStatusRingPainter extends CustomPainter {
  const ConnectedStatusRingPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.shortestSide / 2 - 4;
    if (radius <= 0) {
      return;
    }
    for (var i = 4; i >= 1; i--) {
      canvas.drawCircle(
        size.center(Offset.zero),
        radius,
        Paint()
          ..color = color.withValues(alpha: 0.035 * i)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5 + i * 1.4,
      );
    }
    canvas.drawCircle(
      size.center(Offset.zero),
      radius,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(ConnectedStatusRingPainter oldDelegate) {
    return color != oldDelegate.color;
  }
}

class CoreStatusButton extends ConsumerStatefulWidget {
  const CoreStatusButton({super.key});

  @override
  ConsumerState<CoreStatusButton> createState() => _CoreStatusButtonState();
}

class _CoreStatusButtonState extends ConsumerState<CoreStatusButton> {
  static const _holdDuration = Duration(milliseconds: 600);

  Timer? _holdTimer;
  CoreStatus _status = CoreStatus.disconnected;

  @override
  void initState() {
    super.initState();
    _status = ref.read(coreStatusProvider);
    ref.listenManual(coreStatusProvider, (_, next) {
      _onStatusChanged(next);
    });
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  void _onStatusChanged(CoreStatus next) {
    setState(() {
      _status = next;
      switch (next) {
        case CoreStatus.connecting:
          _holdTimer ??= Timer(_holdDuration, () {
            if (mounted) {
              setState(() {
                _holdTimer = null;
              });
            }
          });
          break;
        case CoreStatus.disconnected:
          _holdTimer?.cancel();
          _holdTimer = null;
          break;
        case CoreStatus.connected:
          break;
      }
    });
  }

  Future<void> _handleConnection() async {
    if (_holdTimer != null) {
      return;
    }
    final coreStatus = ref.read(coreStatusProvider);
    if (coreStatus == CoreStatus.connecting) {
      return;
    }
    final tip = coreStatus == CoreStatus.connected
        ? context.appLocalizations.forceRestartCoreTip
        : context.appLocalizations.restartCoreTip;
    final res = await dialogs.showMessage(message: TextSpan(text: tip));
    if (res != true) {
      return;
    }
    try {
      await ref.read(coreActionProvider.notifier).restartCore();
    } catch (error) {
      dialogs.showNotifier(error.toString(), level: MessageLevel.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coreStatus = _holdTimer != null ? CoreStatus.connecting : _status;
    final appLocalizations = context.appLocalizations;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColors = (
      connected: isDark ? const Color(0xFF17382D) : const Color(0xFFDFF6EC),
      idle: isDark ? const Color(0xFF2A303A) : const Color(0xFFEEF0F6),
    );
    final foregroundColors = (
      connected: isDark ? const Color(0xFF74DDB7) : const Color(0xFF2E9E78),
      idle: isDark ? const Color(0xFFBCC4D1) : const Color(0xFF626A7B),
    );
    return Tooltip(
      message: switch (coreStatus) {
        CoreStatus.connecting => appLocalizations.connecting,
        CoreStatus.connected => appLocalizations.connected,
        CoreStatus.disconnected => appLocalizations.disconnected,
      },
      child: FadeScaleBox(
        alignment: Alignment.centerRight,
        child: CustomPaint(
          foregroundPainter: coreStatus == CoreStatus.connected
              ? const ConnectedStatusRingPainter(color: Color(0xFF209C69))
              : null,
          child: IconButton.filled(
            key: ValueKey(coreStatus),
            visualDensity: VisualDensity.compact,
            iconSize: 22,
            onPressed: _handleConnection,
            style: IconButton.styleFrom(
              backgroundColor: switch (coreStatus) {
                CoreStatus.connected => backgroundColors.connected,
                CoreStatus.connecting =>
                  context.colorScheme.surfaceContainerHigh,
                CoreStatus.disconnected => backgroundColors.idle,
              },
              foregroundColor: switch (coreStatus) {
                CoreStatus.connected => foregroundColors.connected,
                CoreStatus.connecting ||
                CoreStatus.disconnected => foregroundColors.idle,
              },
            ),
            icon: SizedBox.square(
              dimension: 22,
              child: switch (coreStatus) {
                CoreStatus.connecting => Padding(
                  padding: const EdgeInsets.all(2),
                  child: CommonCircleLoading(
                    color: context.colorScheme.onSurfaceVariant,
                  ),
                ),
                CoreStatus.connected ||
                CoreStatus.disconnected => PaperPlaneStatusIcon(
                  disconnected: coreStatus == CoreStatus.disconnected,
                ),
              },
            ),
          ),
        ),
      ),
    );
  }
}
