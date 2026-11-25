import 'medication_service.dart';

class MedicationReminderOccurrence {
  const MedicationReminderOccurrence(
    this.medication,
    this.scheduledAt,
    this.remindAt, {
    required this.snoozed,
  });

  final MedicationSchedule medication;
  final DateTime scheduledAt;
  final DateTime remindAt;
  final bool snoozed;

  // Keep a snoozed alarm separate from the original dose alarm.
  String get alarmKey =>
      '${medication.id}_${scheduledAt.millisecondsSinceEpoch}${snoozed ? '_snooze' : ''}';
}

/// Builds alarms from dose outcomes as well as schedules. A snooze keeps the
/// original dose identity even when its reminder moves into the following day.
List<MedicationReminderOccurrence> medicationReminderPlan({
  required List<MedicationSchedule> schedules,
  required List<MedicationRecord> records,
  required DateTime now,
  int limitPerMedication = 64,
}) {
  final result = <MedicationReminderOccurrence>[];
  for (final medication in schedules.where((m) => m.hasAutomaticReminder)) {
    final responses = <String, MedicationRecord>{};
    for (final record in records.where(
      (r) => r.medicationId == medication.id,
    )) {
      final key = MedicationController.recordKeyFor(
        medication,
        record.scheduledAt,
      );
      final aligned = MedicationController.alignRecordToOccurrence(
        record,
        medication,
        medication.timesPerDay == 1
            ? MedicationController.scheduledDateTime(
                medication,
                record.scheduledAt,
              )
            : record.scheduledAt,
      );
      final previous = responses[key];
      responses[key] = previous == null
          ? aligned
          : deduplicateMedicationRecords([
              previous.copyWith(scheduleSnapshot: medication),
              aligned.copyWith(scheduleSnapshot: medication),
            ]).single;
    }

    for (final record in responses.values) {
      if (record.status == MedicationStatus.snoozed &&
          record.snoozedUntil?.isAfter(now) == true &&
          medication.isScheduledOn(record.scheduledAt)) {
        result.add(
          MedicationReminderOccurrence(
            medication,
            record.scheduledAt,
            record.snoozedUntil!,
            snoozed: true,
          ),
        );
      }
    }

    var day = MedicationController.dateOnly(now);
    if (medication.startDate != null && medication.startDate!.isAfter(day)) {
      day = MedicationController.dateOnly(medication.startDate!);
    }
    final end = medication.endDate == null
        ? null
        : MedicationController.dateOnly(medication.endDate!);
    var checkedOccurrences = 0;
    for (
      var checkedDays = 0;
      checkedDays < 3660 && checkedOccurrences < limitPerMedication;
      checkedDays++
    ) {
      if (end != null && day.isAfter(end)) break;
      if (medication.isScheduledOn(day)) {
        for (final occurrence in MedicationController.scheduledOccurrences(
          medication,
          day,
        )) {
          if (!occurrence.isAfter(now)) continue;
          if (checkedOccurrences++ >= limitPerMedication) break;
          final response =
              responses[MedicationController.recordKeyFor(
                medication,
                occurrence,
              )];
          if (response != null && response.status != MedicationStatus.pending) {
            continue;
          }
          result.add(
            MedicationReminderOccurrence(
              medication,
              occurrence,
              occurrence,
              snoozed: false,
            ),
          );
        }
      }
      day = DateTime(day.year, day.month, day.day + 1);
    }
  }
  result.sort((a, b) => a.remindAt.compareTo(b.remindAt));
  return result;
}
