import 'package:flutter_test/flutter_test.dart';
import 'package:shca/services/medication_service.dart';
import 'package:shca/services/medication_reminder_plan.dart';

const medicine = MedicationSchedule(
  id: 'medicine',
  name: 'Medicine',
  dose: '1 tablet',
  instruction: 'After food',
  category: 'Daily',
  hour: 9,
  minute: 0,
  visual: 'tablet',
);
const twice = MedicationSchedule(
  id: 'twice',
  name: 'Two doses',
  dose: '1 tablet',
  instruction: 'After food',
  category: 'Daily',
  hour: 9,
  minute: 0,
  visual: 'tablet',
  reminderMinutes: [540, 1200],
);

void main() {
  final now = DateTime(2026, 11, 18, 8);
  final due = DateTime(2026, 11, 18, 9);
  for (final status in [MedicationStatus.taken, MedicationStatus.missed]) {
    test(
      'a dose marked ${status.name} early stays absent after rebuilding',
      () {
        final plan = medicationReminderPlan(
          schedules: [medicine],
          records: [
            MedicationRecord(
              medicationId: medicine.id,
              scheduledAt: due,
              status: status,
              actionAt: now,
              scheduleSnapshot: medicine,
            ),
          ],
          now: now,
          limitPerMedication: 2,
        );
        expect(plan.map((a) => a.scheduledAt), [DateTime(2026, 11, 19, 9)]);
      },
    );
  }
  test('answering the morning dose keeps the evening dose', () {
    final plan = medicationReminderPlan(
      schedules: [twice],
      records: [
        MedicationRecord(
          medicationId: twice.id,
          scheduledAt: due,
          status: MedicationStatus.taken,
          actionAt: now,
          scheduleSnapshot: twice,
        ),
      ],
      now: now,
      limitPerMedication: 2,
    );
    expect(plan.single.scheduledAt, DateTime(2026, 11, 18, 20));
  });
  test(
    'snooze replaces the original and keeps the dose identity across midnight',
    () {
      final tomorrow = DateTime(2026, 11, 19, 0, 5);
      final plan = medicationReminderPlan(
        schedules: [medicine],
        records: [
          MedicationRecord(
            medicationId: medicine.id,
            scheduledAt: due,
            status: MedicationStatus.snoozed,
            actionAt: now,
            snoozedUntil: tomorrow,
            scheduleSnapshot: medicine,
          ),
        ],
        now: DateTime(2026, 11, 19, 0, 1),
        limitPerMedication: 1,
      );
      expect(plan.first.scheduledAt, due);
      expect(plan.first.remindAt, tomorrow);
      expect(plan.first.snoozed, isTrue);
      expect(plan.last.scheduledAt, DateTime(2026, 11, 19, 9));
    },
  );
  test('an unanswered future dose is scheduled', () {
    final plan = medicationReminderPlan(
      schedules: [medicine],
      records: [],
      now: now,
      limitPerMedication: 1,
    );
    expect(plan.single.scheduledAt, due);
  });
  test(
    'older pending data cannot revive a taken single daily dose after a time edit',
    () {
      final plan = medicationReminderPlan(
        schedules: [medicine],
        records: [
          MedicationRecord(
            medicationId: medicine.id,
            scheduledAt: DateTime(2026, 11, 18, 8, 30),
            status: MedicationStatus.taken,
            actionAt: now,
            scheduleSnapshot: medicine,
          ),
          MedicationRecord(
            medicationId: medicine.id,
            scheduledAt: due,
            status: MedicationStatus.pending,
            scheduleSnapshot: medicine,
          ),
        ],
        now: now,
        limitPerMedication: 1,
      );
      expect(plan, isEmpty);
    },
  );
  test('a caregiver time edit clears an earlier snooze', () {
    final old = DateTime(2026, 11, 18, 8, 30);
    final plan = medicationReminderPlan(
      schedules: [medicine],
      records: [
        MedicationRecord(
          medicationId: medicine.id,
          scheduledAt: old,
          status: MedicationStatus.snoozed,
          actionAt: now,
          snoozedUntil: DateTime(2026, 11, 18, 8, 40),
          scheduleSnapshot: medicine,
        ),
      ],
      now: now,
      limitPerMedication: 1,
    );
    expect(plan.single.scheduledAt, due);
    expect(plan.single.remindAt, due);
    expect(plan.single.snoozed, isFalse);
  });
}
