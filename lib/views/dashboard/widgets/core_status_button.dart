import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'paper_plane_status_icon.dart';

export 'paper_plane_status_icon.dart';

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
    return Tooltip(
      message: switch (coreStatus) {
        CoreStatus.connecting => appLocalizations.connecting,
        CoreStatus.connected => appLocalizations.connected,
        CoreStatus.disconnected => appLocalizations.disconnected,
      },
      child: FadeScaleBox(
        alignment: Alignment.centerRight,
        child: IconButton.filled(
          key: ValueKey(coreStatus),
          visualDensity: VisualDensity.compact,
          iconSize: 22,
          onPressed: _handleConnection,
          style: IconButton.styleFrom(
            backgroundColor: switch (coreStatus) {
              CoreStatus.connected => Colors.green.harmonizeWith(
                context.colorScheme.primary,
              ),
              CoreStatus.connecting => context.colorScheme.surfaceContainerHigh,
              CoreStatus.disconnected => context.colorScheme.outlineVariant,
            },
            foregroundColor: switch (coreStatus) {
              CoreStatus.connected => context.colorScheme.onPrimary,
              CoreStatus.connecting ||
              CoreStatus.disconnected => context.colorScheme.onSurfaceVariant,
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
    );
  }
}
