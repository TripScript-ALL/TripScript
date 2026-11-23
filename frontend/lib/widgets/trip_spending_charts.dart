import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/trip.dart';
import '../utils/exchange_rates.dart';
import '../utils/format_money.dart';
import '../utils/trip_daily_spending.dart';

const double _kChartTopInset = 14.0;
const double _kBottomAxisReserved = 34.0;
const double _kBarTopLabelReserved = 16.0;

int _chartLabelStep(int n) {
  if (n <= 8) return 1;
  if (n <= 16) return 2;
  if (n <= 31) return 4;
  return (n / 8).ceil().clamp(1, 16);
}

/// 막대 위 짧은 금액 (만 단위 / 작은 액수는 `원` 포함)
String _barTopAmountText(double v) {
  if (v <= 0) return '';
  if (v >= 10000) {
    return formatManDecimal1(v);
  }
  return '${formatWonInt(v)}원';
}

/// [BarChartAlignment.spaceBetween] — 첫/막 막대가 플롯 **양끝**에 붙고, 사이만 균등.
List<double> _barCenterXsSpaceBetween({
  required int n,
  required double barWidth,
  required double usableWidth,
}) {
  if (n <= 0 || usableWidth <= 0) return [];
  if (n == 1) {
    return [usableWidth / 2];
  }
  final sumWidth = n * barWidth;
  final spaceAvailable = usableWidth - sumWidth;
  final eachSpace = spaceAvailable / (n - 1);
  var tempX = 0.0;
  final groupsX = <double>[];
  for (var i = 0; i < n; i++) {
    tempX += barWidth / 2;
    if (i != 0) {
      tempX += eachSpace;
    }
    groupsX.add(tempX);
    tempX += barWidth / 2;
  }
  return groupsX;
}

/// 막대·누적 그래프 공통: 안쪽 패딩(x축 날짜 잘림 방지).
Widget _chartPlotFrame({required Widget child}) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
    child: child,
  );
}

/// 일별 막대 + 누적 선을 한 영역에 겹쳐 표시
/// (막대 상단·날짜 x축; Y축 눈금은 없음)
class TripSpendingCharts extends StatefulWidget {
  final Trip trip;

  const TripSpendingCharts({super.key, required this.trip});

  @override
  State<TripSpendingCharts> createState() => _TripSpendingChartsState();
}

class _TripSpendingChartsState extends State<TripSpendingCharts> {
  bool _expanded = false;

  Trip get _trip => widget.trip;

  Widget _buildChartContent(
    BuildContext context,
    ColorScheme colorScheme,
    Color onVar,
    List<TripDaySpending> days,
  ) {
    final maxDaily =
        days.map((e) => e.daily).fold<double>(0, (a, b) => a > b ? a : b);
    final maxCum =
        days.map((e) => e.cumulative).fold<double>(0, (a, b) => a > b ? a : b);
    final barMaxY = maxDaily <= 0 ? 1.0 : maxDaily * 1.12;
    final lineMaxY = maxCum <= 0 ? 1.0 : maxCum * 1.16;

    final n = days.length;
    final step = _chartLabelStep(n);
    final last = n - 1;

    final barGroups = <BarChartGroupData>[
      for (var i = 0; i < n; i++)
        BarChartGroupData(
          x: i,
          barRods: [
            BarChartRodData(
              fromY: 0,
              toY: days[i].daily,
              color: colorScheme.primary.withValues(alpha: 0.88),
              width: n > 20 ? 5 : 8,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(3)),
            ),
          ],
        ),
    ];

    Widget bottomLabel(int i) {
      final d = days[i].day;
      return Text(
        '${d.month}/${d.day}',
        style: TextStyle(fontSize: 10, color: onVar),
      );
    }

    FlTitlesData titlesForBarFront() {
      return FlTitlesData(
        show: true,
        topTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: _kBarTopLabelReserved,
            interval: 1,
            getTitlesWidget: (value, meta) {
              final i = value.toInt();
              if (i < 0 || i >= n) return const SizedBox.shrink();
              final text = _barTopAmountText(days[i].daily);
              if (text.isEmpty) return const SizedBox.shrink();
              return SideTitleWidget(
                axisSide: meta.axisSide,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    text,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 8.5,
                      height: 1.0,
                      color: onVar,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: _kBottomAxisReserved,
            getTitlesWidget: (value, meta) {
              final i = value.toInt();
              if (i < 0 || i >= n) return const SizedBox.shrink();
              if (i != 0 && i != last && i % step != 0) {
                return const SizedBox.shrink();
              }
              return SideTitleWidget(
                axisSide: meta.axisSide,
                space: 4,
                child: bottomLabel(i),
              );
            },
          ),
        ),
        rightTitles: const AxisTitles(
          sideTitles: SideTitles(
            showTitles: false,
            reservedSize: 0,
          ),
        ),
        leftTitles: const AxisTitles(
          sideTitles: SideTitles(
            showTitles: false,
            reservedSize: 0,
          ),
        ),
      );
    }

    FlTitlesData titlesForLineBack() {
      return FlTitlesData(
        show: true,
        topTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: _kBarTopLabelReserved,
            interval: 1,
            getTitlesWidget: (_, __) => const SizedBox.shrink(),
          ),
        ),
        leftTitles: const AxisTitles(
          sideTitles: SideTitles(
            showTitles: false,
            reservedSize: 0,
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: _kBottomAxisReserved,
            getTitlesWidget: (value, meta) {
              final i = value.toInt();
              if (i < 0 || i >= n) return const SizedBox.shrink();
              if (i != 0 && i != last && i % step != 0) {
                return const SizedBox.shrink();
              }
              final d = days[i].day;
              return SideTitleWidget(
                axisSide: meta.axisSide,
                space: 4,
                child: Text(
                  '${d.month}/${d.day}',
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.transparent,
                  ),
                ),
              );
            },
          ),
        ),
        rightTitles: const AxisTitles(
          sideTitles: SideTitles(
            showTitles: false,
            reservedSize: 0,
          ),
        ),
      );
    }

    final t = barMaxY / 3;
    final barGrid = FlGridData(
      show: true,
      drawVerticalLine: false,
      horizontalInterval: t,
      getDrawingHorizontalLine: (v) => FlLine(
        color: colorScheme.outlineVariant.withValues(alpha: 0.4),
        strokeWidth: 1,
      ),
      checkToShowHorizontalLine: (v) {
        if (!v.isFinite || v < -1e-6) return false;
        if (v > barMaxY + 1e-2) return false;
        if ((v - barMaxY).abs() < (barMaxY * 0.01).clamp(1e-2, 1.0)) {
          return false;
        }
        return true;
      },
    );

    final barData = BarChartData(
      backgroundColor: Colors.transparent,
      barGroups: barGroups,
      maxY: barMaxY,
      minY: 0,
      alignment:
          n <= 1 ? BarChartAlignment.center : BarChartAlignment.spaceBetween,
      gridData: barGrid,
      borderData: FlBorderData(show: false),
      titlesData: titlesForBarFront(),
      barTouchData: BarTouchData(
        touchTooltipData: BarTouchTooltipData(
          getTooltipColor: (_) => colorScheme.surfaceContainerHighest,
          tooltipPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          fitInsideHorizontally: true,
          fitInsideVertically: true,
          getTooltipItem: (group, groupIndex, rod, rodIndex) {
            final i = group.x.toInt();
            if (i < 0 || i >= days.length) return null;
            return BarTooltipItem(
              formatWonLabel(days[i].daily),
              TextStyle(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w100,
                fontSize: 13,
              ),
            );
          },
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.bar_chart, size: 14, color: colorScheme.primary),
            const SizedBox(width: 4),
            Text(
              '일별',
              style: TextStyle(fontSize: 12, color: onVar),
            ),
            const SizedBox(width: 12),
            Icon(Icons.show_chart, size: 14, color: colorScheme.tertiary),
            const SizedBox(width: 4),
            Text(
              '누적',
              style: TextStyle(fontSize: 12, color: onVar),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 260,
          child: LayoutBuilder(
            builder: (context, constraints) {
              const minPlotWidthPerDay = 28.0;

              final viewportW = constraints.maxWidth;
              final naturalPlotW = viewportW.clamp(1.0, double.infinity);
              final minPlotW = n * minPlotWidthPerDay;
              final plotW = math.max(naturalPlotW, minPlotW);
              final chartW = plotW;

              final barW = n > 20 ? 5.0 : 8.0;
              final centers = _barCenterXsSpaceBetween(
                n: n,
                barWidth: barW,
                usableWidth: plotW,
              );

              final lineSpots = <FlSpot>[
                for (var i = 0; i < n; i++)
                  FlSpot(
                    n <= 1 ? 0.5 : (centers[i] / plotW) * (n - 1),
                    days[i].cumulative,
                  ),
              ];

              final lineData = LineChartData(
                minX: 0,
                maxX: n <= 1 ? 1.0 : (n - 1).toDouble(),
                minY: 0,
                maxY: lineMaxY,
                clipData: const FlClipData.all(),
                backgroundColor: Colors.transparent,
                gridData: const FlGridData(show: false),
                borderData: FlBorderData(show: false),
                titlesData: titlesForLineBack(),
                lineTouchData: const LineTouchData(enabled: false),
                lineBarsData: [
                  LineChartBarData(
                    spots: lineSpots,
                    color: colorScheme.tertiary,
                    barWidth: 2.5,
                    dotData: FlDotData(
                      show: n <= 24,
                      getDotPainter: (s, p, bar, i) {
                        return FlDotCirclePainter(
                          radius: n > 24 ? 2 : 3,
                          color: colorScheme.tertiary,
                          strokeWidth: 0,
                        );
                      },
                    ),
                    belowBarData: BarAreaData(
                      show: true,
                      color: colorScheme.tertiary.withValues(alpha: 0.10),
                    ),
                  ),
                ],
              );

              final chartStack = _chartPlotFrame(
                child: Padding(
                  padding: const EdgeInsets.only(top: _kChartTopInset),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: BarChart(barData),
                      ),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: LineChart(lineData),
                        ),
                      ),
                    ],
                  ),
                ),
              );

              if (chartW <= viewportW + 0.5) {
                return chartStack;
              }

              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: chartW,
                  height: 260,
                  child: chartStack,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final onVar = colorScheme.onSurfaceVariant;
    final days = computeTripDailySpending(_trip);
    final hasChartData = _trip.receipts.isNotEmpty && days.isNotEmpty;
    final collapsedSubtitle = !hasChartData
        ? '표시할 지출이 없습니다'
        : '합계 ${formatWonLabel(tripTotalInKrw(_trip))}';

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.insights_outlined,
                        size: 22,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '지출 추이',
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: colorScheme.onSurface,
                                ),
                      ),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: _expanded
                              ? const SizedBox.shrink()
                              : Text(
                                  collapsedSubtitle,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: onVar,
                                        height: 1.35,
                                      ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.end,
                                ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _expanded ? '간단히' : '자세히',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: colorScheme.primary,
                            ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        color: colorScheme.primary,
                        size: 22,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            ClipRect(
              child: AnimatedSize(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: _expanded
                    ? Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: hasChartData
                            ? _buildChartContent(
                                context,
                                colorScheme,
                                onVar,
                                days,
                              )
                            : _chartPlotFrame(
                                child: SizedBox(
                                  height: 140,
                                  width: double.infinity,
                                  child: Center(
                                    child: Text(
                                      '지출이 없습니다',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(color: onVar),
                                    ),
                                  ),
                                ),
                              ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
