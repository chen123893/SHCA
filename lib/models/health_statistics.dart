import 'dart:math' as math;

/// Only recorded observations are counted. No monitoring coverage is inferred.
class StatisticsDose {
  const StatisticsDose({
    required this.key,
    required this.scheduledAt,
    required this.status,
    this.actionAt,
  });
  final String key;
  final DateTime scheduledAt;
  final String status;
  final DateTime? actionAt;
}

class StatisticsFall {
  const StatisticsFall({required this.detectedAt, required this.status});
  final DateTime detectedAt;
  final String status;
}

class StatisticsDay {
  StatisticsDay(this.date);
  final DateTime date;
  int taken = 0;
  int missed = 0;
  int unresolved = 0;
  int alerts = 0;
  int get doses => taken + missed + unresolved;
  double? get completion => doses == 0 ? null : taken / doses * 100;
}

class CompletionOutlook {
  const CompletionOutlook(
    this.percent,
    this.lower,
    this.upper,
    this.recordDays,
  );
  final double percent;
  final double lower;
  final double upper;
  final int recordDays;
}

enum SmartInsightTone { positive, attention, neutral }

class SmartInsight {
  const SmartInsight({
    required this.title,
    required this.body,
    required this.tone,
  });

  final String title;
  final String body;
  final SmartInsightTone tone;
}

class SmartInsights {
  const SmartInsights({
    required this.headline,
    required this.summary,
    required this.items,
    required this.confidenceLabel,
    required this.confidenceDetail,
    required this.confidenceValue,
  });

  final String headline;
  final String summary;
  final List<SmartInsight> items;
  final String confidenceLabel;
  final String confidenceDetail;
  final double confidenceValue;

  factory SmartInsights.fromStatistics(HealthStatistics statistics) {
    final recordLimit = math.min(statistics.days.length, 14);
    final doseLimit = math.min(statistics.days.length * 2, 28);
    final confidenceValue =
        (statistics.recordDays / math.max(1, recordLimit) * 0.5 +
                statistics.doses / math.max(1, doseLimit) * 0.5)
            .clamp(0.0, 1.0);
    final confidenceLabel = switch (confidenceValue) {
      >= 0.75 => 'Strong',
      >= 0.4 => 'Growing',
      _ => 'Limited',
    };
    final confidenceDetail = switch (confidenceLabel) {
      'Strong' => 'Enough saved history for a useful pattern summary.',
      'Growing' =>
        'Useful early patterns; more recorded days will improve context.',
      _ => 'A small amount of history can only show basic observations.',
    };

    if (statistics.doses == 0 && statistics.alerts == 0) {
      return SmartInsights(
        headline: 'Your insights will grow with your records',
        summary:
            'No medication actions or possible-fall alerts were saved in this period.',
        items: const [
          SmartInsight(
            title: 'Nothing to compare yet',
            body:
                'Record medication actions and keep monitoring active. SHCA will summarize patterns automatically.',
            tone: SmartInsightTone.neutral,
          ),
        ],
        confidenceLabel: confidenceLabel,
        confidenceDetail: confidenceDetail,
        confidenceValue: confidenceValue,
      );
    }

    final completion = statistics.completion;
    final headline = completion == null
        ? 'Safety activity was recorded'
        : completion >= 90
        ? 'Medication routine looks consistent'
        : completion >= 75
        ? 'Medication routine is mostly on track'
        : 'Your routine may need extra support';
    final summary = [
      if (statistics.doses > 0)
        '${statistics.doses} saved dose ${statistics.doses == 1 ? 'record' : 'records'} across ${statistics.recordDays} ${statistics.recordDays == 1 ? 'day' : 'days'}',
      if (statistics.alerts > 0)
        '${statistics.alerts} possible-fall ${statistics.alerts == 1 ? 'alert' : 'alerts'}',
    ].join(' and ');

    final items = <SmartInsight>[];
    final comparison = _completionComparison(statistics);
    if (comparison != null) {
      final difference = comparison.recent - comparison.previous;
      if (difference >= 5) {
        items.add(
          SmartInsight(
            title: 'Recorded completion improved',
            body:
                'The latest ${comparison.days}-day window was ${difference.abs().toStringAsFixed(0)} percentage points higher than the previous window.',
            tone: SmartInsightTone.positive,
          ),
        );
      } else if (difference <= -5) {
        items.add(
          SmartInsight(
            title: 'Recorded completion declined',
            body:
                'The latest ${comparison.days}-day window was ${difference.abs().toStringAsFixed(0)} percentage points lower than the previous window. A reminder or caregiver check-in may help.',
            tone: SmartInsightTone.attention,
          ),
        );
      } else {
        items.add(
          SmartInsight(
            title: 'Recorded completion is steady',
            body:
                'The latest ${comparison.days}-day window is close to the previous window.',
            tone: SmartInsightTone.positive,
          ),
        );
      }
    } else if (completion != null) {
      items.add(
        SmartInsight(
          title: '${completion.toStringAsFixed(0)}% recorded completion',
          body:
              'This is based on saved doses due by now. More history is needed for a fair trend comparison.',
          tone: completion >= 75
              ? SmartInsightTone.positive
              : SmartInsightTone.attention,
        ),
      );
    }

    if (statistics.missed == 0 &&
        statistics.unresolved == 0 &&
        statistics.doses > 0) {
      items.add(
        const SmartInsight(
          title: 'No follow-up records',
          body:
              'No doses were marked missed, pending, snoozed or unknown in this period.',
          tone: SmartInsightTone.positive,
        ),
      );
    } else if (statistics.missed > 0 || statistics.unresolved > 0) {
      final parts = [
        if (statistics.missed > 0) '${statistics.missed} marked missed',
        if (statistics.unresolved > 0) '${statistics.unresolved} unresolved',
      ];
      items.add(
        SmartInsight(
          title: 'Some dose records need attention',
          body:
              '${parts.join(' and ')}. Unresolved records are kept separate and are not assumed to be missed.',
          tone: SmartInsightTone.attention,
        ),
      );
    }

    if (statistics.alerts == 0) {
      items.add(
        const SmartInsight(
          title: 'No possible-fall alerts recorded',
          body:
              'This describes saved alerts only. It does not prove that no fall occurred or that monitoring covered every moment.',
          tone: SmartInsightTone.neutral,
        ),
      );
    } else {
      final peak = _peakAlertPeriod(statistics.alertHours);
      final sent = statistics.fallStatuses['Alert sent'] ?? 0;
      items.add(
        SmartInsight(
          title:
              '${statistics.alerts} possible-fall ${statistics.alerts == 1 ? 'alert' : 'alerts'} recorded',
          body: [
            'Most were recorded during $peak.',
            if (sent > 0)
              '$sent ${sent == 1 ? 'alert resulted' : 'alerts resulted'} in emergency action.',
            'These are sensor alerts, not confirmed falls.',
          ].join(' '),
          tone: sent > 0
              ? SmartInsightTone.attention
              : SmartInsightTone.neutral,
        ),
      );
    }

    return SmartInsights(
      headline: headline,
      summary: '$summary. Generated privately on this device.',
      items: items,
      confidenceLabel: confidenceLabel,
      confidenceDetail: confidenceDetail,
      confidenceValue: confidenceValue,
    );
  }

  static _CompletionComparison? _completionComparison(
    HealthStatistics statistics,
  ) {
    final today = HealthStatistics.dateOnly(statistics.asOf);
    final completedDays = statistics.days
        .where((day) => day.date.isBefore(today))
        .toList();
    final window = math.min(7, completedDays.length ~/ 2);
    if (window < 3) return null;
    final recent = completedDays.sublist(completedDays.length - window);
    final previous = completedDays.sublist(
      completedDays.length - window * 2,
      completedDays.length - window,
    );
    double? rate(List<StatisticsDay> days) {
      final doses = days.fold(0, (total, day) => total + day.doses);
      final recordDays = days.where((day) => day.doses > 0).length;
      if (doses < 5 || recordDays < 3) return null;
      final taken = days.fold(0, (total, day) => total + day.taken);
      return taken / doses * 100;
    }

    final recentRate = rate(recent);
    final previousRate = rate(previous);
    if (recentRate == null || previousRate == null) return null;
    return _CompletionComparison(recentRate, previousRate, window);
  }

  static String _peakAlertPeriod(List<int> hours) {
    final labels = ['overnight', 'morning', 'afternoon', 'evening'];
    var peak = 0;
    for (var index = 1; index < hours.length; index++) {
      if (hours[index] > hours[peak]) peak = index;
    }
    return labels[peak];
  }
}

class _CompletionComparison {
  const _CompletionComparison(this.recent, this.previous, this.days);

  final double recent;
  final double previous;
  final int days;
}

class HealthStatistics {
  HealthStatistics._(
    this.start,
    this.asOf,
    this.days,
    this.fallStatuses,
    this.alertHours,
    this.invalidRecords,
  );

  final DateTime start;
  final DateTime asOf;
  final List<StatisticsDay> days;
  final Map<String, int> fallStatuses;
  final List<int> alertHours;
  final int invalidRecords;
  int get taken => days.fold(0, (n, d) => n + d.taken);
  int get missed => days.fold(0, (n, d) => n + d.missed);
  int get unresolved => days.fold(0, (n, d) => n + d.unresolved);
  int get doses => taken + missed + unresolved;
  int get alerts => days.fold(0, (n, d) => n + d.alerts);
  int get recordDays => days.where((d) => d.doses > 0).length;
  double? get completion => doses == 0 ? null : taken / doses * 100;
  SmartInsights get smartInsights => SmartInsights.fromStatistics(this);

  /// Historical baseline, not a clinical model. Excludes the unfinished day.
  /// Wilson interval describes uncertainty in recorded completion, not a
  /// calibrated prediction interval for a person's future behaviour.
  CompletionOutlook? get outlook {
    final today = dateOnly(asOf);
    final complete = days.where((d) => d.date.isBefore(today) && d.doses > 0);
    if (complete.length < 7) return null;
    final n = complete.fold(0, (n, d) => n + d.doses);
    if (n < 14) return null;
    final successes = complete.fold(0, (n, d) => n + d.taken);
    final p = successes / n;
    const z = 1.96;
    final denominator = 1 + z * z / n;
    final center = (p + z * z / (2 * n)) / denominator;
    final margin =
        z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denominator;
    return CompletionOutlook(
      p * 100,
      (center - margin) * 100,
      (center + margin) * 100,
      complete.length,
    );
  }

  factory HealthStatistics.calculate({
    required DateTime now,
    required int periodDays,
    required Iterable<StatisticsDose> doses,
    required Iterable<StatisticsFall> falls,
    int invalidRecords = 0,
  }) {
    if (![1, 7, 30, 90].contains(periodDays)) {
      throw ArgumentError.value(
        periodDays,
        'periodDays',
        'Use 1, 7, 30 or 90 days',
      );
    }
    final localNow = now.toLocal();
    final today = dateOnly(localNow);
    final start = DateTime(today.year, today.month, today.day - periodDays + 1);
    final days = List.generate(
      periodDays,
      (i) => StatisticsDay(DateTime(start.year, start.month, start.day + i)),
    );
    final byDate = {for (final day in days) dateKey(day.date): day};
    final unique = <String, StatisticsDose>{};
    for (final dose in doses) {
      final time = dose.scheduledAt.toLocal();
      if (time.isBefore(start) || time.isAfter(localNow)) continue;
      if (dose.key.isEmpty) {
        invalidRecords++;
        continue;
      }
      final previous = unique[dose.key];
      if (previous == null || _prefer(dose, previous)) unique[dose.key] = dose;
    }
    for (final dose in unique.values) {
      final day = byDate[dateKey(dose.scheduledAt.toLocal())]!;
      switch (dose.status) {
        case 'taken':
          day.taken++;
        case 'missed':
          day.missed++;
        default:
          day.unresolved++;
      }
    }
    final statuses = <String, int>{
      'Alert sent': 0,
      'Cancelled': 0,
      'Unresolved': 0,
    };
    final hours = List.filled(4, 0);
    for (final fall in falls) {
      final time = fall.detectedAt.toLocal();
      if (time.isBefore(start) || time.isAfter(localNow)) continue;
      byDate[dateKey(time)]!.alerts++;
      hours[time.hour ~/ 6]++;
      final label = switch (fall.status) {
        'alert_sent' => 'Alert sent',
        'cancelled' => 'Cancelled',
        _ => 'Unresolved',
      };
      statuses[label] = statuses[label]! + 1;
    }
    return HealthStatistics._(
      start,
      localNow,
      days,
      statuses,
      hours,
      invalidRecords,
    );
  }

  static bool _prefer(StatisticsDose a, StatisticsDose b) {
    final aTime = a.actionAt?.millisecondsSinceEpoch ?? 0;
    final bTime = b.actionAt?.millisecondsSinceEpoch ?? 0;
    if (aTime != bTime) return aTime > bTime;
    int rank(String status) => switch (status) {
      'taken' => 3,
      'missed' => 2,
      'snoozed' => 1,
      _ => 0,
    };
    return rank(a.status) > rank(b.status);
  }

  static DateTime dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);
  static String dateKey(DateTime value) =>
      '${value.year}-${value.month}-${value.day}';
}
