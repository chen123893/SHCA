import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shca/models/health_statistics.dart';
import 'package:shca/services/statistics_pdf_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('statistics report builds a valid one-page PDF', () async {
    final statistics = HealthStatistics.calculate(
      now: DateTime(2026, 9, 21, 12),
      periodDays: 7,
      doses: <StatisticsDose>[
        StatisticsDose(
          key: 'vitamin-d:2026-9-21',
          scheduledAt: DateTime(2026, 9, 21, 8),
          status: 'taken',
          actionAt: DateTime(2026, 9, 21, 8, 2),
        ),
        StatisticsDose(
          key: 'metformin:2026-9-20',
          scheduledAt: DateTime(2026, 9, 20, 20),
          status: 'missed',
        ),
      ],
      falls: <StatisticsFall>[
        StatisticsFall(
          detectedAt: DateTime(2026, 9, 20, 10),
          status: 'cancelled',
        ),
      ],
    );

    final bytes = await const StatisticsPdfService().buildReport(
      personName: 'George Tan',
      statistics: statistics,
      fromCache: false,
    );

    expect(utf8.decode(bytes.take(4).toList()), '%PDF');
    expect(bytes.length, greaterThan(2000));
    final source = latin1.decode(bytes);
    expect(RegExp(r'/Type\s*/Page\b').allMatches(source), hasLength(1));
  });

  test('export periods provide day, week, month and quarter choices', () {
    expect(statisticsExportPeriods[1], 'Today');
    expect(statisticsExportPeriods[7], 'Last 7 days');
    expect(statisticsExportPeriods[30], 'Last 30 days');
    expect(statisticsExportPeriods[90], 'Last 90 days');
  });
}
