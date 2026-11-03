import 'package:flutter_test/flutter_test.dart';
import 'package:shca/models/health_statistics.dart';

void main() {
  final now = DateTime(2026, 9, 21, 12);
  HealthStatistics calculate(
    List<StatisticsDose> doses, {
    List<StatisticsFall> falls = const [],
    int days = 30,
  }) => HealthStatistics.calculate(
    now: now,
    periodDays: days,
    doses: doses,
    falls: falls,
  );
  StatisticsDose dose(
    String key,
    DateTime time,
    String status, {
    DateTime? action,
  }) => StatisticsDose(
    key: key,
    scheduledAt: time,
    status: status,
    actionAt: action,
  );

  test('empty history has no completion and no forecast', () {
    final data = calculate([]);
    expect(data.completion, isNull);
    expect(data.outlook, isNull);
    expect(data.days.length, 30);
    expect(data.days.every((day) => day.completion == null), isTrue);
  });
  test('today export range includes only the current local day', () {
    final data = calculate([
      dose('today', DateTime(2026, 9, 21, 8), 'taken'),
      dose('yesterday', DateTime(2026, 9, 20, 8), 'missed'),
    ], days: 1);
    expect(data.days, hasLength(1));
    expect(data.taken, 1);
    expect(data.missed, 0);
  });
  test('deduplicates legacy rows and prefers the newest action', () {
    final day = DateTime(2026, 9, 20, 8);
    final data = calculate([
      dose('same', day, 'pending'),
      dose('same', day, 'taken', action: DateTime(2026, 9, 20, 9)),
      dose('same', day, 'missed', action: DateTime(2026, 9, 20, 10)),
    ]);
    expect(data.doses, 1);
    expect(data.missed, 1);
    expect(data.taken, 0);
  });
  test('future doses excluded; unresolved are not marked missed', () {
    final data = calculate([
      dose('one', DateTime(2026, 9, 21, 8), 'taken'),
      dose('two', DateTime(2026, 9, 21, 9), 'snoozed'),
      dose('three', DateTime(2026, 9, 21, 10), 'unrecognized'),
      dose('future', DateTime(2026, 9, 21, 20), 'pending'),
      dose('old', DateTime(2026, 7, 1), 'taken'),
    ]);
    expect(data.doses, 3);
    expect(data.unresolved, 2);
    expect(data.missed, 0);
    expect(data.completion, closeTo(100 / 3, .001));
  });
  test('calendar boundaries and alert statuses are counted separately', () {
    final data = calculate(
      [],
      days: 7,
      falls: [
        StatisticsFall(
          detectedAt: DateTime(2026, 9, 14, 23, 59),
          status: 'alert_sent',
        ),
        StatisticsFall(detectedAt: DateTime(2026, 9, 15), status: 'cancelled'),
        StatisticsFall(
          detectedAt: DateTime(2026, 9, 20, 6),
          status: 'alert_sent',
        ),
        StatisticsFall(
          detectedAt: DateTime(2026, 9, 20, 15),
          status: 'pending_confirmation',
        ),
        StatisticsFall(
          detectedAt: DateTime(2026, 9, 20, 20),
          status: 'unknown',
        ),
        StatisticsFall(
          detectedAt: DateTime(2026, 9, 21, 20),
          status: 'alert_sent',
        ),
      ],
    );
    expect(data.alerts, 4);
    expect(data.fallStatuses, {
      'Alert sent': 1,
      'Cancelled': 1,
      'Unresolved': 2,
    });
    expect(data.alertHours, [1, 1, 1, 1]);
  });
  test('outlook requires seven complete recorded days and excludes today', () {
    final doses = [
      for (var day = 14; day <= 20; day++)
        for (var i = 0; i < 2; i++)
          dose(
            '$day-$i',
            DateTime(2026, 9, day, 8 + i),
            i == 0 ? 'taken' : 'missed',
          ),
    ];
    final data = calculate(doses);
    expect(data.outlook!.percent, 50);
    expect(data.outlook!.recordDays, 7);
    expect(data.outlook!.lower, lessThan(50));
    expect(data.outlook!.upper, greaterThan(50));
    expect(calculate(doses.skip(2).toList()).outlook, isNull);
    expect(calculate(doses, days: 7).outlook, isNull);
    expect(
      calculate([...doses, dose('today', now, 'taken')]).outlook!.percent,
      50,
    );
  });
  test('smart insights handle empty history without making safety claims', () {
    final insights = calculate([]).smartInsights;
    expect(insights.headline, 'Your insights will grow with your records');
    expect(insights.confidenceLabel, 'Limited');
    expect(insights.items.single.body, contains('Record medication actions'));
  });
  test('smart insights compare equal completed windows', () {
    final doses = <StatisticsDose>[];
    for (var day = 7; day <= 13; day++) {
      doses.add(dose('$day-a', DateTime(2026, 9, day, 8), 'missed'));
      doses.add(dose('$day-b', DateTime(2026, 9, day, 9), 'taken'));
    }
    for (var day = 14; day <= 20; day++) {
      doses.add(dose('$day-a', DateTime(2026, 9, day, 8), 'taken'));
      doses.add(dose('$day-b', DateTime(2026, 9, day, 9), 'taken'));
    }
    final insights = calculate(doses).smartInsights;
    expect(insights.items.first.title, 'Recorded completion improved');
    expect(insights.items.first.body, contains('50 percentage points'));
    expect(insights.confidenceLabel, 'Strong');
  });
  test('smart insights explain alert peak and sensor limits', () {
    final insights = calculate(
      [],
      falls: [
        StatisticsFall(
          detectedAt: DateTime(2026, 9, 18, 9),
          status: 'cancelled',
        ),
        StatisticsFall(
          detectedAt: DateTime(2026, 9, 19, 10),
          status: 'alert_sent',
        ),
      ],
    ).smartInsights;
    expect(insights.items.single.body, contains('during morning'));
    expect(insights.items.single.body, contains('not confirmed falls'));
  });
}
