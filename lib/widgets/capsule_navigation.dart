import 'package:fl_clash/common/common.dart';
import 'package:material_ui/material_ui.dart';

class CapsuleNavigationItem {
  const CapsuleNavigationItem({required this.icon, required this.label});

  final Widget icon;
  final String label;
}

class CapsuleNavigation extends StatelessWidget {
  const CapsuleNavigation({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
  });

  static const surfaceKey = ValueKey<String>('capsule-navigation-surface');

  final List<CapsuleNavigationItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      top: false,
      left: false,
      right: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                key: surfaceKey,
                width: constraints.maxWidth * 0.76,
                height: 66,
                child: Material(
                  color: colorScheme.surfaceContainerLow,
                  elevation: 2,
                  shadowColor: colorScheme.shadow,
                  shape: AppShape.full,
                  clipBehavior: Clip.antiAlias,
                  child: Row(
                    children: [
                      for (var index = 0; index < items.length; index++)
                        Expanded(
                          child: _CapsuleNavigationButton(
                            item: items[index],
                            selected: index == selectedIndex,
                            onPressed: () => onSelected(index),
                            textStyle: textTheme.labelMedium,
                            colorScheme: colorScheme,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _CapsuleNavigationButton extends StatelessWidget {
  const _CapsuleNavigationButton({
    required this.item,
    required this.selected,
    required this.onPressed,
    required this.textStyle,
    required this.colorScheme,
  });

  final CapsuleNavigationItem item;
  final bool selected;
  final VoidCallback onPressed;
  final TextStyle? textStyle;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final color = selected ? colorScheme.primary : colorScheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconTheme.merge(
                data: IconThemeData(color: color, size: 24),
                child: item.icon,
              ),
              const SizedBox(height: 2),
              Flexible(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: textStyle?.copyWith(color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
