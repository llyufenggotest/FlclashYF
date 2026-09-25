import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class NetworkSpeed extends StatefulWidget {
  const NetworkSpeed({super.key, @visibleForTesting this.traffics});

  final List<Traffic>? traffics;

  @override
  State<NetworkSpeed> createState() => _NetworkSpeedState();
}

class _NetworkSpeedState extends State<NetworkSpeed> {
  static const _initialPoints = [Point(0, 0), Point(1, 0)];

  List<Point> _getPoints(List<Traffic> traffics) {
    const maxLength = 30;
    final paddingCount = maxLength - traffics.length;
    final trafficPoints = List.generate(maxLength, (index) {
      final speed = index < paddingCount
          ? 0.0
          : traffics[index - paddingCount].speed.toDouble();
      return Point((index + _initialPoints.length).toDouble(), speed);
    });
    return [..._initialPoints, ...trafficPoints];
  }

  Traffic _getLastTraffic(List<Traffic> traffics) {
    return traffics.isEmpty ? const Traffic() : traffics.last;
  }

  Widget _metric(BuildContext context, String direction, num value) {
    final traffic = value.traffic;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          direction,
          style: context.textTheme.labelSmall?.copyWith(
            color: context.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          '${traffic.show}/s',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.textTheme.bodyMedium?.toJetBrainsMono,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: getWidgetHeight(1),
      child: RepaintBoundary(
        child: CommonCard(
          radius: AppCorner.lg,
          onPressed: () {},
          child: Consumer(
            builder: (_, ref, _) {
              final traffics =
                  widget.traffics ?? ref.watch(trafficsProvider).list;
              final current = _getLastTraffic(traffics);
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.speed_outlined,
                      color: context.colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(child: _metric(context, '↑', current.up)),
                          const SizedBox(width: 8),
                          Expanded(child: _metric(context, '↓', current.down)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 96,
                      height: 36,
                      child: LineChart(
                        gradient: true,
                        color: context.colorScheme.primary,
                        points: _getPoints(traffics),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
