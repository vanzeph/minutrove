import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/domain.dart';
import '../../ui/core/core.dart';
import 'stats_model.dart';

class StatsChart extends StatelessWidget {
  const StatsChart({
    super.key,
    required this.period,
    required this.anchor,
    required this.selection,
    required this.buckets,
    required this.onPrevious,
    required this.onNext,
    required this.onCurrent,
    required this.onChooseDate,
  });
  final StatsPeriod period;
  final DayKey anchor;
  final StatsSelection selection;
  final List<StatsBucket> buckets;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onCurrent;
  final VoidCallback onChooseDate;

  @override
  Widget build(BuildContext context) {
    final total = buckets.fold(
      BigInt.zero,
      (total, bucket) => total + BigInt.from(bucket.value),
    );
    final unit = statsUnit(selection.metric, selection.currency);
    final value = statsValue(total, selection.metric, selection.currency);
    final name = periodName(period);
    final color = switch (selection.metric) {
      StatsMetric.coinsEarned || StatsMetric.coinsSpent => TroveTokens.coin,
      StatsMetric.gemsEarned || StatsMetric.gemsSpent => TroveTokens.gem,
      _ => TroveTokens.primary,
    };
    return Material(
      key: ValueKey('chart-${period.name}'),
      color: Colors.white,
      borderRadius: BorderRadius.circular(TroveTokens.tileRadius),
      child: Padding(
        padding: const EdgeInsets.all(TroveTokens.space20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                '$name · ${periodLabel(period, anchor)}',
                style: TroveTokens.heading,
              ),
            ),
            const SizedBox(height: 8),
            Semantics(
              label:
                  '$name ${metricName(selection.metric)}, $value $unit in ${periodLabel(period, anchor)}',
              excludeSemantics: true,
              child: Text(
                '$value $unit · ${metricName(selection.metric)}',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
            ),
            const SizedBox(height: 16),
            _Plot(
              period: period,
              buckets: buckets,
              selection: selection,
              color: color,
            ),
            if (total == BigInt.zero) ...[
              const SizedBox(height: 12),
              const Text(
                'No activity in this period. Missing buckets appear as zero.',
              ),
            ],
            const SizedBox(height: 12),
            TroveFormRow(
              children: [
                Semantics(
                  label: 'Previous $name period',
                  button: true,
                  enabled: onPrevious != null,
                  onTap: onPrevious,
                  excludeSemantics: true,
                  child: TroveButton(
                    label: '‹',
                    secondary: true,
                    onPressed: onPrevious,
                  ),
                ),
                Semantics(
                  label: 'Current $name period',
                  button: true,
                  enabled: true,
                  onTap: onCurrent,
                  excludeSemantics: true,
                  child: TroveButton(
                    label: 'Current',
                    secondary: true,
                    onPressed: onCurrent,
                  ),
                ),
                Semantics(
                  label: 'Next $name period',
                  button: true,
                  enabled: onNext != null,
                  onTap: onNext,
                  excludeSemantics: true,
                  child: TroveButton(
                    label: '›',
                    secondary: true,
                    onPressed: onNext,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TroveButton(
              label: 'Choose ${name.toLowerCase()} date',
              secondary: true,
              onPressed: onChooseDate,
            ),
            ExpansionTile(
              key: PageStorageKey('values-${period.name}'),
              title: const Text('View values'),
              tilePadding: EdgeInsets.zero,
              children: [
                for (final bucket in buckets)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '${bucketLabel(period, bucket)}: ${statsValue(BigInt.from(bucket.value), selection.metric, selection.currency)} $unit',
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Plot extends StatelessWidget {
  const _Plot({
    required this.period,
    required this.buckets,
    required this.selection,
    required this.color,
  });
  final StatsPeriod period;
  final List<StatsBucket> buckets;
  final StatsSelection selection;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final maximum = buckets.fold(0, (max, b) => math.max(max, b.value));
    // Nonzero axis even for an empty period; the line itself remains at zero.
    final axisMax = maximum == 0
        ? switch (selection.metric) {
            StatsMetric.questTime || StatsMetric.awardTime => 60000,
            StatsMetric.coinsEarned ||
            StatsMetric.coinsSpent ||
            StatsMetric.gemsEarned ||
            StatsMetric.gemsSpent => 1000000,
            _ => 1,
          }
        : maximum;
    final maxLabel = statsValue(
      BigInt.from(axisMax),
      selection.metric,
      selection.currency,
    );
    final scaler = MediaQuery.textScalerOf(context);
    final style = Theme.of(context).textTheme.bodySmall!;
    final measure = TextPainter(
      text: TextSpan(text: maxLabel, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final yWidth = measure.width + 12;
    final labelHeight = measure.height;
    measure.dispose();
    final slotWidth = scaler.scale(38);
    final width =
        math.max(250.0, slotWidth * (period == StatsPeriod.weekly ? 7 : 6)) +
        yWidth;
    final height = math.max(124.0, scaler.scale(100));
    final indices = switch (period) {
      StatsPeriod.daily => [0, 6, 12, 18, 23],
      StatsPeriod.weekly => [0, 1, 2, 3, 4, 5, 6],
      StatsPeriod.monthly => [0, 7, 14, 21, buckets.length - 1],
      StatsPeriod.yearly => [0, 2, 4, 6, 8, 11],
    };
    return ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: math.max(width, constraints.maxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  statsUnit(selection.metric, selection.currency),
                  style: style,
                ),
                SizedBox(
                  height: height + labelHeight,
                  child: Row(
                    children: [
                      SizedBox(
                        width: yWidth,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(maxLabel, style: style),
                            Text('0', style: style),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            vertical: labelHeight / 2,
                          ),
                          child: CustomPaint(
                            size: Size(double.infinity, height),
                            painter: StatsPlotPainter(
                              values: buckets.map((b) => b.value).toList(),
                              maximum: axisMax,
                              graph: selection.graph,
                              color: color,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: EdgeInsets.only(left: yWidth),
                  child: SizedBox(
                    height: labelHeight + 8,
                    child: LayoutBuilder(
                      builder: (context, plot) => Stack(
                        children: [
                          for (final index in indices.where(
                            (i) => i >= 0 && i < buckets.length,
                          ))
                            Positioned(
                              left:
                                  ((index + .5) /
                                              buckets.length *
                                              plot.maxWidth -
                                          slotWidth / 2)
                                      .clamp(0, plot.maxWidth - slotWidth),
                              width: slotWidth,
                              child: Text(
                                period == StatsPeriod.weekly
                                    ? statsWeekdays[buckets[index]
                                              .start
                                              .weekday -
                                          1]
                                    : bucketLabel(period, buckets[index]),
                                textAlign: TextAlign.center,
                                style: style.copyWith(fontSize: 10),
                                maxLines: 1,
                              ),
                            ),
                        ],
                      ),
                    ),
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

/// Double conversion is limited to plot positions. Totals and readable values
/// retain integer precision and never pass through floating-point arithmetic.
class StatsPlotPainter extends CustomPainter {
  StatsPlotPainter({
    required this.values,
    required this.maximum,
    required this.graph,
    required this.color,
  });
  final List<int> values;
  final int maximum;
  final StatsGraph graph;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = TroveTokens.line
      ..strokeWidth = 1;
    for (final fraction in [0.0, .5, 1.0]) {
      canvas.drawLine(
        Offset(0, size.height * fraction),
        Offset(size.width, size.height * fraction),
        grid,
      );
    }
    if (values.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final step = size.width / values.length;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = (i + .5) * step;
      final y = size.height * (1 - values[i] / maximum);
      if (graph == StatsGraph.bars) {
        if (values[i] == 0) continue;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(x - step * .32, y, x + step * .32, size.height),
            const Radius.circular(2),
          ),
          paint,
        );
      } else {
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
        canvas.drawCircle(Offset(x, y), 2.5, paint);
      }
    }
    if (graph == StatsGraph.lines) {
      canvas.drawPath(path, paint..style = PaintingStyle.stroke);
    }
  }

  @override
  bool shouldRepaint(StatsPlotPainter oldDelegate) => true;
}
