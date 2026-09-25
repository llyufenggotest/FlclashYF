import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class MemoryInfo extends ConsumerStatefulWidget {
  const MemoryInfo({super.key, @visibleForTesting this.memoryReader});

  final Future<num> Function()? memoryReader;

  @override
  ConsumerState<MemoryInfo> createState() => _MemoryInfoState();
}

class _MemoryInfoState extends ConsumerState<MemoryInfo>
    with WidgetsBindingObserver, ActivePollingMixin<MemoryInfo> {
  final _coreMemory = ValueNotifier<num?>(null);

  CoreController get _core => ref.read(coreHandlerProvider);

  @override
  Duration get pollInterval => const Duration(seconds: 2);

  @override
  void dispose() {
    _coreMemory.dispose();
    super.dispose();
  }

  @override
  Future<void> poll(PollGuard isCurrent) async {
    final coreMemory = await _readCoreMemory();
    if (!isCurrent()) return;
    if (coreMemory != null) {
      _coreMemory.value = coreMemory;
    }
  }

  Future<num?> _readCoreMemory() async {
    try {
      return widget.memoryReader != null
          ? await widget.memoryReader!()
          : await _core.getMemory();
    } catch (error) {
      commonPrint.log(
        'updateMemory error: $error',
        logLevel: coreFailureLogLevel(error),
      );
      return null;
    }
  }

  Widget _value(BuildContext context, String label, num? bytes) {
    final traffic = bytes?.traffic;
    final text = traffic == null ? '—' : '${traffic.value}${traffic.unit}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.textTheme.labelSmall?.copyWith(
            color: context.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.textTheme.titleMedium?.toJetBrainsMono,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    return SizedBox(
      height: getWidgetHeight(1),
      child: RepaintBoundary(
        child: CommonCard(
          radius: AppCorner.lg,
          onPressed: _core.requestGc,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.memory_outlined, color: context.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: ValueListenableBuilder(
                    valueListenable: _coreMemory,
                    builder: (_, coreMemory, _) =>
                        _value(context, l10n.core, coreMemory),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
