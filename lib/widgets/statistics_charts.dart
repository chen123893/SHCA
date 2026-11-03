import 'dart:math' as math;
import 'package:flutter/material.dart';

const statisticsOrange = Color(0xFFFF8128);
const statisticsGreen = Color(0xFF35865A);
const statisticsRed = Color(0xFFC84640);
const statisticsMuted = Color(0xFF8B817A);

class StatisticsSeriesChart extends StatelessWidget {
  const StatisticsSeriesChart({
    super.key,
    required this.values,
    required this.labels,
    required this.unit,
    this.percent = false,
    this.bars = false,
  });
  final List<double?> values;
  final List<String> labels;
  final String unit;
  final bool percent;
  final bool bars;

  @override
  Widget build(BuildContext context) {
    final observed = values.whereType<double>().toList();
    if (observed.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text('No recorded data for this chart.'),
      );
    }
    final maxValue = percent
        ? 100.0
        : math.max(1.0, observed.reduce(math.max)).ceilToDouble();
    return Column(
      children: [
        Row(
          children: [
            Text(
              '${maxValue.toStringAsFixed(0)} $unit',
              style: const TextStyle(fontSize: 12, color: statisticsMuted),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 145,
          width: double.infinity,
          child: ExcludeSemantics(
            child: CustomPaint(painter: _SeriesPainter(values, maxValue, bars)),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children:
              [
                    Text(labels.first),
                    Text(labels[labels.length ~/ 2]),
                    Text(labels.last),
                  ]
                  .map(
                    (text) => DefaultTextStyle(
                      style: const TextStyle(
                        fontSize: 11,
                        color: statisticsMuted,
                      ),
                      child: text,
                    ),
                  )
                  .toList(),
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text(
            'View daily values',
            style: TextStyle(fontSize: 13),
          ),
          children: [
            for (var i = 0; i < values.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(child: Text(labels[i])),
                    Text(
                      values[i] == null
                          ? 'No records'
                          : '${values[i]!.toStringAsFixed(percent ? 1 : 0)} $unit',
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _SeriesPainter extends CustomPainter {
  _SeriesPainter(this.values, this.maxValue, this.bars);
  final List<double?> values;
  final double maxValue;
  final bool bars;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = const Color(0xFFEDE6E0)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = 6 + (size.height - 12) * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final step = size.width / values.length;
    final stroke = Paint()
      ..color = bars ? statisticsRed : statisticsOrange
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    final fill = Paint()..color = bars ? statisticsRed : statisticsOrange;
    Offset? previous;
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      if (value == null) {
        previous = null;
        continue;
      }
      final x = step * (i + 0.5);
      final y = size.height - 6 - value / maxValue * (size.height - 12);
      final point = Offset(x, y);
      if (bars) {
        if (value > 0) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTRB(x - step * .3, y, x + step * .3, size.height - 6),
              const Radius.circular(3),
            ),
            fill,
          );
        }
      } else {
        if (previous != null) canvas.drawLine(previous, point, stroke);
        canvas.drawCircle(point, values.length > 30 ? 2 : 3.5, fill);
      }
      previous = point;
    }
  }

  @override
  bool shouldRepaint(_SeriesPainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.maxValue != maxValue ||
      oldDelegate.bars != bars;
}

class StatisticsBreakdown extends StatelessWidget {
  const StatisticsBreakdown({
    super.key,
    required this.values,
    required this.colors,
  });
  final Map<String, int> values;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    final total = values.values.fold(0, (a, b) => a + b);
    return Column(
      children: [
        SizedBox(
          height: 160,
          width: 160,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: ExcludeSemantics(
                  child: CustomPaint(
                    painter: _DonutPainter(values.values.toList(), colors),
                  ),
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$total',
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Text(
                    'records',
                    style: TextStyle(color: statisticsMuted),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        for (var i = 0; i < values.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: colors[i],
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(child: Text(values.keys.elementAt(i))),
                Text(
                  '${values.values.elementAt(i)}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.values, this.colors);
  final List<int> values;
  final List<Color> colors;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(12, 12, size.width - 24, size.height - 24);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 16;
    canvas.drawOval(rect, paint..color = const Color(0xFFEDE6E0));
    final total = values.fold(0, (a, b) => a + b);
    if (total == 0) return;
    var start = -math.pi / 2;
    for (var i = 0; i < values.length; i++) {
      final sweep = values[i] / total * math.pi * 2;
      canvas.drawArc(rect, start, sweep, false, paint..color = colors[i]);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.colors != colors;
}
