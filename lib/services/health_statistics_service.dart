import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shca/models/health_statistics.dart';

class StatisticsHistory {
  const StatisticsHistory(this.statistics, {this.fromCache = false});
  final HealthStatistics statistics;
  final bool fromCache;
}

abstract class HealthStatisticsRepository {
  Future<StatisticsHistory> load(
    String elderlyId,
    int periodDays,
    DateTime now,
  );
}

class FirestoreHealthStatisticsRepository
    implements HealthStatisticsRepository {
  @override
  Future<StatisticsHistory> load(
    String elderlyId,
    int periodDays,
    DateTime now,
  ) async {
    final today = HealthStatistics.dateOnly(now.toLocal());
    final start = DateTime(today.year, today.month, today.day - periodDays + 1);
    final db = FirebaseFirestore.instance;
    Query<Map<String, dynamic>> query(String collection, String field) => db
        .collection(collection)
        .where('elderlyId', isEqualTo: elderlyId)
        .where(field, isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .where(field, isLessThanOrEqualTo: Timestamp.fromDate(now))
        .orderBy(field, descending: true)
        .limit(2001);
    final results = await Future.wait([
      query('medication_records', 'scheduledAt').get(),
      query('fall_events', 'detectedAt').get(),
    ]);
    if (results.any((result) => result.docs.length > 2000)) {
      throw StateError(
        'There are too many records for this view. Choose a shorter period.',
      );
    }
    var invalid = 0;
    final doses = <StatisticsDose>[];
    final falls = <StatisticsFall>[];
    for (final doc in results[0].docs) {
      final data = doc.data();
      final time = data['scheduledAt'];
      final medicine = data['medicationId'];
      if (time is! Timestamp || medicine is! String || medicine.isEmpty) {
        invalid++;
        continue;
      }
      final scheduled = time.toDate().toLocal();
      final action = data['actionAt'];
      // Match the existing app's schedule/date uniqueness, including legacy rows.
      doses.add(
        StatisticsDose(
          key: '$medicine:${HealthStatistics.dateKey(scheduled)}',
          scheduledAt: scheduled,
          status: data['status'] is String
              ? data['status'] as String
              : 'unknown',
          actionAt: action is Timestamp ? action.toDate() : null,
        ),
      );
    }
    for (final doc in results[1].docs) {
      final data = doc.data();
      final time = data['detectedAt'];
      if (time is! Timestamp) {
        invalid++;
        continue;
      }
      falls.add(
        StatisticsFall(
          detectedAt: time.toDate(),
          status: data['status'] is String
              ? data['status'] as String
              : 'unknown',
        ),
      );
    }
    return StatisticsHistory(
      HealthStatistics.calculate(
        now: now,
        periodDays: periodDays,
        doses: doses,
        falls: falls,
        invalidRecords: invalid,
      ),
      fromCache: results.any((result) => result.metadata.isFromCache),
    );
  }
}
