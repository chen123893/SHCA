import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shca/screens/auth/caregiver_medication_schedule.dart';
import 'package:shca/screens/auth/medication.dart';
import 'package:shca/services/care_link_service.dart';
import 'package:shca/services/medication_image_service.dart';
import 'package:shca/services/medication_service.dart';
import 'package:shca/services/push_notification_service.dart';
import 'package:shca/services/watch_schedule_sync.dart';

class _DelayedMedicationRepository extends _FakeMedicationRepository {
  _DelayedMedicationRepository(this.ready, super.schedules, {super.records});

  final Future<void> ready;

  @override
  Future<List<MedicationSchedule>> loadSchedules(String elderlyId) async {
    await ready;
    return super.loadSchedules(elderlyId);
  }
}

class _FakeMedicationRepository implements MedicationRepository {
  _FakeMedicationRepository(
    this.schedules, {
    List<MedicationRecord> records = const <MedicationRecord>[],
  }) : records = List<MedicationRecord>.of(records);

  List<MedicationSchedule> schedules;
  List<MedicationRecord> records;
  final List<String> loadedScheduleElderlyIds = <String>[];
  final List<String> loadedRecordElderlyIds = <String>[];

  @override
  Future<List<MedicationSchedule>> loadSchedules(String elderlyId) async {
    loadedScheduleElderlyIds.add(elderlyId);
    return List<MedicationSchedule>.of(schedules);
  }

  @override
  Future<void> saveSchedules(
    String elderlyId,
    List<MedicationSchedule> updates, {
    String? createdByCaregiverId,
    bool schedulesAreNew = false,
  }) async {
    for (final update in updates) {
      final index = schedules.indexWhere((item) => item.id == update.id);
      if (index == -1) {
        schedules.add(update);
      } else {
        schedules[index] = update;
      }
    }
  }

  @override
  Future<void> deleteSchedule(String elderlyId, String scheduleId) async {
    schedules.removeWhere((schedule) => schedule.id == scheduleId);
  }

  @override
  Future<List<MedicationRecord>> loadRecords(String elderlyId) async {
    loadedRecordElderlyIds.add(elderlyId);
    return List<MedicationRecord>.of(records);
  }

  @override
  Future<void> saveRecord(String elderlyId, MedicationRecord record) async {
    final index = records.indexWhere((item) => item.key == record.key);
    if (index == -1) {
      records.add(record);
    } else {
      records[index] = record;
    }
  }
}

const _linkedElderly = LinkedElderly(
  id: 'elderly-id',
  fullName: 'George Tan',
  email: 'george@example.com',
  emergencyPhone: '01100000000',
  relationship: 'Father',
);

const _secondLinkedElderly = LinkedElderly(
  id: 'elderly-id-2',
  fullName: 'Mary Lim',
  email: 'mary@example.com',
  emergencyPhone: '01200000000',
  relationship: 'Mother',
);

const sampleSchedules = <MedicationSchedule>[
  MedicationSchedule(
    id: 'vitamin_d',
    name: 'Vitamin D',
    dose: '1 tablet',
    instruction: 'Before meal',
    category: 'Calcium',
    hour: 8,
    minute: 0,
    visual: 'vitamin',
  ),
  MedicationSchedule(
    id: 'blood_pressure',
    name: 'Blood Pressure',
    dose: '1 tablet',
    instruction: 'Before meal',
    category: 'Blood pressure',
    hour: 10,
    minute: 0,
    visual: 'tablet',
  ),
  MedicationSchedule(
    id: 'metformin',
    name: 'Metformin',
    dose: '2 tablets',
    instruction: 'After meal',
    category: 'Diabetes',
    hour: 20,
    minute: 0,
    visual: 'tablet',
  ),
];

void main() {
  test('taken dose reduces stock without going below zero', () {
    expect(medicationStockAfterTakenDose(14, 2), 12);
    expect(medicationStockAfterTakenDose(1, 2), 0);
    expect(medicationStockAfterTakenDose(null, 2), isNull);
  });

  test(
    'multiple daily dose times round-trip and stay independently tracked',
    () async {
      const schedule = MedicationSchedule(
        id: 'antibiotic',
        name: 'Antibiotic',
        dose: '500 mg',
        instruction: 'After meal',
        category: 'Antibiotic',
        hour: 8,
        minute: 0,
        visual: 'tablet',
        reminderMinutes: <int>[8 * 60, 20 * 60],
      );

      final restored = MedicationSchedule.fromFirestore(
        schedule.toFirestore('elderly-id'),
      );
      expect(restored.dailyReminderMinutes, <int>[480, 1200]);
      expect(restored.timesPerDay, 2);

      final controller = MedicationController.preview(
        now: DateTime(2026, 9, 9, 9),
        schedules: const <MedicationSchedule>[schedule],
      );
      final doses = controller.recordsFor(schedule, date: DateTime(2026, 9, 9));
      expect(doses, hasLength(2));
      expect(doses[0].key, '2026-09-09_0800_antibiotic');
      expect(doses[1].key, '2026-09-09_2000_antibiotic');

      await controller.markTaken(schedule, scheduledAt: doses[1].scheduledAt);
      expect(
        controller
            .recordFor(schedule, scheduledAt: doses[0].scheduledAt)
            .status,
        MedicationStatus.pending,
      );
      expect(
        controller
            .recordFor(schedule, scheduledAt: doses[1].scheduledAt)
            .status,
        MedicationStatus.taken,
      );
    },
  );

  test(
    'edited single-dose time replaces the stale daily record time',
    () async {
      final today = MedicationController.dateOnly(DateTime.now());
      const oldSchedule = MedicationSchedule(
        id: 'test-alarm',
        name: 'Test alarm',
        dose: '1 tablet',
        instruction: 'Before meal',
        category: '',
        hour: 8,
        minute: 0,
        visual: 'tablet',
      );
      const updatedSchedule = MedicationSchedule(
        id: 'test-alarm',
        name: 'Test alarm',
        dose: '1 tablet',
        instruction: 'Before meal',
        category: '',
        hour: 0,
        minute: 17,
        visual: 'tablet',
      );
      final repository = _FakeMedicationRepository(
        <MedicationSchedule>[updatedSchedule],
        records: <MedicationRecord>[
          MedicationRecord(
            medicationId: oldSchedule.id,
            scheduledAt: DateTime(today.year, today.month, today.day, 8),
            status: MedicationStatus.snoozed,
            actionAt: DateTime(today.year, today.month, today.day, 8, 1),
            snoozedUntil: DateTime(today.year, today.month, today.day, 8, 10),
            scheduleSnapshot: oldSchedule,
          ),
        ],
      );
      final controller = MedicationController(
        storageScope: 'elderly-id',
        repository: repository,
      );

      await controller.load();

      final record = controller.recordsFor(updatedSchedule).single;
      expect(record.scheduledAt.hour, 0);
      expect(record.scheduledAt.minute, 17);
      expect(record.status, MedicationStatus.pending);
      expect(record.actionAt, isNull);
      expect(record.snoozedUntil, isNull);
      expect(repository.records.single.scheduledAt.hour, 0);
      expect(repository.records.single.scheduledAt.minute, 17);
    },
  );

  testWidgets('snoozed card shows the new reminder time', (tester) async {
    final today = MedicationController.dateOnly(DateTime.now());
    const schedule = MedicationSchedule(
      id: 'test-alarm',
      name: 'Test alarm',
      dose: '1 tablet',
      instruction: 'Before meal',
      category: '',
      hour: 0,
      minute: 17,
      visual: 'tablet',
    );
    final controller = MedicationController.preview(
      now: today,
      schedules: const <MedicationSchedule>[schedule],
      records: <MedicationRecord>[
        MedicationRecord(
          medicationId: schedule.id,
          scheduledAt: DateTime(today.year, today.month, today.day, 0, 17),
          status: MedicationStatus.snoozed,
          snoozedUntil: DateTime(today.year, today.month, today.day, 0, 37),
          scheduleSnapshot: schedule,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(home: MedicationReminderScreen(controller: controller)),
    );
    await tester.pump();

    expect(find.text('Snoozed'), findsOneWidget);
    expect(find.text('12:37 AM'), findsWidgets);
    expect(find.text('Reminder moved to 12:37 AM'), findsOneWidget);
  });

  test(
    'caregiver time update clears a snooze from before the new dose',
    () async {
      final today = MedicationController.dateOnly(DateTime.now());
      const schedule = MedicationSchedule(
        id: 'test-alarm',
        name: 'Test alarm',
        dose: '1 tablet',
        instruction: 'Before meal',
        category: '',
        hour: 0,
        minute: 59,
        visual: 'tablet',
      );
      final repository = _FakeMedicationRepository(
        <MedicationSchedule>[schedule],
        records: <MedicationRecord>[
          MedicationRecord(
            medicationId: schedule.id,
            scheduledAt: DateTime(today.year, today.month, today.day, 0, 59),
            status: MedicationStatus.snoozed,
            actionAt: DateTime(today.year, today.month, today.day, 0, 22),
            snoozedUntil: DateTime(today.year, today.month, today.day, 0, 32),
            scheduleSnapshot: schedule,
          ),
        ],
      );
      final controller = MedicationController(
        storageScope: 'elderly-id',
        repository: repository,
      );

      await controller.load();

      final record = controller.recordsFor(schedule).single;
      expect(record.scheduledAt.minute, 59);
      expect(record.status, MedicationStatus.pending);
      expect(record.actionAt, isNull);
      expect(record.snoozedUntil, isNull);
    },
  );

  test('watch sync creates one row for every daily dose time', () {
    const schedule = MedicationSchedule(
      id: 'twice-daily',
      name: 'Twice daily medicine',
      dose: '1 tablet',
      instruction: 'After meal',
      category: '',
      hour: 8,
      minute: 0,
      visual: 'tablet',
      reminderMinutes: <int>[480, 1200],
    );
    final rows = todayWatchDoses(
      const <MedicationSchedule>[schedule],
      const <MedicationRecord>[],
      DateTime(2026, 9, 9, 7),
    );
    expect(rows, hasLength(2));
    expect(rows[0]['occurrenceId'], '2026-09-09_0800_twice-daily');
    expect(rows[1]['occurrenceId'], '2026-09-09_2000_twice-daily');
  });

  test('watch receives only today pending or snoozed doses', () {
    final now = DateTime(2026, 9, 9, 10);
    final schedules = <MedicationSchedule>[
      MedicationSchedule(
        id: 'morning',
        name: 'Morning medicine',
        dose: '1 tablet',
        instruction: 'After meal',
        category: '',
        hour: 8,
        minute: 0,
        visual: 'tablet',
      ),
      MedicationSchedule(
        id: 'evening',
        name: 'Evening medicine',
        dose: '1 tablet',
        instruction: 'After meal',
        category: '',
        hour: 20,
        minute: 0,
        visual: 'tablet',
        recurrence: MedicationRecurrence.selectedDays,
        weekdays: const <int>[DateTime.wednesday],
      ),
      MedicationSchedule(
        id: 'tomorrow',
        name: 'Tomorrow only',
        dose: '1 tablet',
        instruction: 'After meal',
        category: '',
        hour: 9,
        minute: 0,
        visual: 'tablet',
        recurrence: MedicationRecurrence.oneTime,
        startDate: DateTime(2026, 9, 10),
      ),
    ];
    final records = <MedicationRecord>[
      MedicationRecord(
        medicationId: 'morning',
        scheduledAt: DateTime(2026, 9, 9, 8),
        status: MedicationStatus.taken,
      ),
      MedicationRecord(
        medicationId: 'evening',
        scheduledAt: DateTime(2026, 9, 9, 20),
        status: MedicationStatus.snoozed,
        snoozedUntil: DateTime(2026, 9, 9, 20, 10),
      ),
    ];

    final rows = todayWatchDoses(schedules, records, now);
    expect(rows, hasLength(1));
    expect(rows.single['name'], 'Evening medicine');
    expect(rows.single['occurrenceId'], '2026-09-09_evening');
    expect(rows.single['status'], 'snoozed');
    expect(
      rows.single['remindAt'],
      DateTime(2026, 9, 9, 20, 10).millisecondsSinceEpoch,
    );
  });

  test('medication time formatting uses a 12-hour clock', () {
    expect(formatMedicationTime(sampleSchedules.first), '8:00 AM');
    expect(formatMedicationTime(sampleSchedules.last), '8:00 PM');
  });

  test('medication notification targets are stable and safely decoded', () {
    final first = PushNotificationService.medicationNotificationId(
      'elderly-id',
      'vitamin_d',
    );
    final repeated = PushNotificationService.medicationNotificationId(
      'elderly-id',
      'vitamin_d',
    );
    final different = PushNotificationService.medicationNotificationId(
      'elderly-id',
      'metformin',
    );
    expect(first, repeated);
    expect(first, isNot(different));

    final target = MedicationNotificationTarget.fromPayload(
      '{"type":"medication_reminder","elderlyId":"elderly-id",'
      '"medicationId":"vitamin_d","scheduledAt":1788912000000}',
    );
    expect(target?.elderlyId, 'elderly-id');
    expect(target?.medicationId, 'vitamin_d');
    expect(target?.scheduledAt?.millisecondsSinceEpoch, 1788912000000);
    expect(target?.reminderAt, isNull);
    expect(target?.belongsTo('elderly-id'), isTrue);
    expect(target?.belongsTo('another-user'), isFalse);
    expect(target?.belongsTo(null), isFalse);
    expect(MedicationNotificationTarget.fromPayload('not-json'), isNull);

    final snoozedTarget = MedicationNotificationTarget.fromPayload(
      '{"type":"medication_reminder","elderlyId":"elderly-id",'
      '"medicationId":"vitamin_d","scheduledAt":1788912000000,'
      '"reminderAt":1788912600000}',
    );
    expect(snoozedTarget?.scheduledAt?.millisecondsSinceEpoch, 1788912000000);
    expect(snoozedTarget?.reminderAt?.millisecondsSinceEpoch, 1788912600000);
  });

  test(
    'local alarm includes serializable medicine details and snooze time',
    () {
      final schedule = MedicationSchedule.fromRecordSnapshot(
        medicationId: sampleSchedules.first.id,
        scheduledAt: DateTime(2026, 10, 21, 8),
        data: {
          ...sampleSchedules.first.toRecordSnapshot(),
          'startDate': '2026-10-01T00:00:00.000',
          'endDate': '2026-10-31T00:00:00.000',
        },
      );
      final original = MedicationNotificationTarget(
        elderlyId: 'elderly-id',
        medicationId: schedule.id,
        medicationSnapshot: schedule,
        scheduledAt: DateTime(2026, 10, 21, 8),
        reminderAt: DateTime(2026, 10, 21, 8, 10),
      );
      final restored = MedicationNotificationTarget.fromPayload(
        original.toPayload(),
      );
      expect(restored?.medicationSnapshot?.id, schedule.id);
      expect(restored?.medicationSnapshot?.name, schedule.name);
      expect(restored?.medicationSnapshot?.doseSummary, schedule.doseSummary);
      expect(restored?.medicationSnapshot?.startDate, DateTime(2026, 10, 1));
      expect(restored?.medicationSnapshot?.endDate, DateTime(2026, 10, 31));
      expect(restored?.scheduledAt, original.scheduledAt);
      expect(restored?.reminderAt, original.reminderAt);
      expect(restored?.belongsTo('another-user'), isFalse);
      final malformed = MedicationNotificationTarget.fromPayload(
        '{"type":"medication_reminder","elderlyId":"elderly-id",'
        '"medicationId":"medication-id","scheduledAt":1788912000000,'
        '"medicationSnapshot":{"name":123}}',
      );
      expect(malformed?.medicationId, 'medication-id');
      expect(malformed?.medicationSnapshot, isNull);
    },
  );

  test('medicine names select the correct local image asset', () {
    expect(medicineAssetFor(sampleSchedules[0]), 'assets/images/vitamin.png');
    expect(medicineAssetFor(sampleSchedules[1]), 'assets/images/tablet.png');
    expect(medicineAssetFor(sampleSchedules[2]), 'assets/images/tablet.png');

    const coughSyrup = MedicationSchedule(
      id: 'cough_syrup',
      name: 'Cough Syrup',
      dose: '5 ml',
      instruction: 'After meal',
      category: 'Liquid',
      hour: 12,
      minute: 0,
      visual: 'liquid',
    );
    expect(medicineAssetFor(coughSyrup), 'assets/images/liquid.png');
  });

  test('medication reminder stores its instruction source confirmation', () {
    const schedule = MedicationSchedule(
      id: 'prescribed_medication',
      name: 'Example medicine',
      dose: '1 tablet',
      instruction: 'After meal',
      category: 'Prescription',
      hour: 9,
      minute: 0,
      visual: 'tablet',
      instructionSource: 'Doctor prescription',
      sourceConfirmed: true,
      quantity: 2,
    );

    final data = schedule.toFirestore('elderly-id');
    expect(data['instructionSource'], 'Doctor prescription');
    expect(data['sourceConfirmed'], isTrue);
    expect(data['quantity'], 2);
    expect(schedule.quantityLabel, '2 tablets');
    expect(schedule.doseSummary, '2 tablets');

    final restored = MedicationSchedule.fromFirestore(data);
    expect(restored.instructionSource, 'Doctor prescription');
    expect(restored.sourceConfirmed, isTrue);
    expect(restored.effectiveQuantity, 2);
  });

  test('medication recurrence survives Firestore conversion', () {
    final schedule = MedicationSchedule(
      id: 'weekday-medicine',
      name: 'Example medicine',
      dose: '10 mg',
      instruction: 'After meal',
      category: 'Prescription',
      hour: 9,
      minute: 30,
      visual: 'tablet',
      recurrence: MedicationRecurrence.selectedDays,
      startDate: DateTime(2026, 9, 7),
      endDate: DateTime(2026, 10, 7),
      weekdays: const <int>[DateTime.monday, DateTime.wednesday],
    );

    final restored = MedicationSchedule.fromFirestore(
      schedule.toFirestore('elderly-id'),
    );
    expect(restored.recurrence, MedicationRecurrence.selectedDays);
    expect(restored.startDate, DateTime(2026, 9, 7));
    expect(restored.endDate, DateTime(2026, 10, 7));
    expect(restored.weekdays, <int>[DateTime.monday, DateTime.wednesday]);
    expect(restored.scheduleSummary, 'Mon, Wed');
    expect(
      restored.treatmentDurationSummary,
      '31-day treatment • 7/9/2026–7/10/2026',
    );
  });

  test('medication scheduling respects days, intervals, and one-time use', () {
    final monday = DateTime(2026, 9, 7);
    final selectedDays = MedicationSchedule(
      id: 'selected',
      name: 'Selected-day medicine',
      dose: '10 mg',
      instruction: 'After meal',
      category: '',
      hour: 9,
      minute: 0,
      visual: 'tablet',
      recurrence: MedicationRecurrence.selectedDays,
      startDate: monday,
      weekdays: const <int>[DateTime.monday, DateTime.friday],
    );
    final interval = MedicationSchedule(
      id: 'interval',
      name: 'Interval medicine',
      dose: '10 mg',
      instruction: 'After meal',
      category: '',
      hour: 9,
      minute: 0,
      visual: 'tablet',
      recurrence: MedicationRecurrence.intervalDays,
      startDate: monday,
      intervalDays: 3,
    );
    final oneTime = MedicationSchedule(
      id: 'once',
      name: 'One-time medicine',
      dose: '10 mg',
      instruction: 'After meal',
      category: '',
      hour: 9,
      minute: 0,
      visual: 'tablet',
      recurrence: MedicationRecurrence.oneTime,
      startDate: monday,
    );
    final asNeeded = MedicationSchedule(
      id: 'needed',
      name: 'As-needed medicine',
      dose: '10 mg',
      instruction: 'Only as directed',
      category: '',
      hour: 9,
      minute: 0,
      visual: 'tablet',
      recurrence: MedicationRecurrence.asNeeded,
      startDate: monday,
    );

    expect(selectedDays.isScheduledOn(monday), isTrue);
    expect(
      selectedDays.isScheduledOn(monday.add(const Duration(days: 1))),
      isFalse,
    );
    expect(interval.isScheduledOn(monday.add(const Duration(days: 3))), isTrue);
    expect(
      interval.isScheduledOn(monday.add(const Duration(days: 2))),
      isFalse,
    );
    expect(oneTime.isScheduledOn(monday), isTrue);
    expect(oneTime.isScheduledOn(monday.add(const Duration(days: 1))), isFalse);
    expect(asNeeded.isScheduledOn(monday), isFalse);
    expect(asNeeded.hasAutomaticReminder, isFalse);
  });

  test('legacy tablet text is converted to an integer quantity', () {
    final restored = MedicationSchedule.fromFirestore(<String, dynamic>{
      'scheduleKey': 'legacy-dose',
      'name': 'Legacy medicine',
      'dose': '3 tablets',
      'instruction': 'After meal',
      'category': 'General',
      'hour': 8,
      'minute': 0,
      'visual': 'tablet',
    });

    expect(restored.effectiveQuantity, 3);
    expect(restored.toFirestore('elderly-id')['quantity'], 3);
    expect(restored.doseSummary, '3 tablets');
  });

  test('medication history preserves a schedule snapshot', () {
    final scheduledAt = DateTime(2026, 9, 6, 8);
    final record = MedicationRecord(
      medicationId: sampleSchedules.first.id,
      scheduledAt: scheduledAt,
      status: MedicationStatus.taken,
      scheduleSnapshot: sampleSchedules.first,
    );

    final data = record.toFirestore('elderly-id');
    expect(data['recordKey'], '2026-09-06_vitamin_d');
    expect(data['scheduleSnapshot'], isA<Map<String, dynamic>>());
    final restored = MedicationRecord.fromFirestore(data);
    expect(restored.scheduleSnapshot?.name, 'Vitamin D');
    expect(restored.scheduleSnapshot?.doseSummary, '1 tablet');
  });

  test('duplicate dated records keep the strongest user action', () {
    final scheduledAt = DateTime(2026, 9, 6, 8);
    final unique = deduplicateMedicationRecords(<MedicationRecord>[
      MedicationRecord(
        medicationId: 'vitamin_d',
        scheduledAt: scheduledAt,
        status: MedicationStatus.pending,
      ),
      MedicationRecord(
        medicationId: 'vitamin_d',
        scheduledAt: scheduledAt,
        status: MedicationStatus.taken,
        actionAt: scheduledAt.add(const Duration(minutes: 2)),
        scheduleSnapshot: sampleSchedules.first,
      ),
    ]);

    expect(unique, hasLength(1));
    expect(unique.single.status, MedicationStatus.taken);
    expect(unique.single.scheduleSnapshot?.name, 'Vitamin D');
  });

  test('identical caregiver reminders are recognised as duplicates', () {
    const duplicate = MedicationSchedule(
      id: 'new-id',
      name: ' vitamin d ',
      dose: '1 TABLET',
      instruction: 'Before meal',
      category: 'Calcium',
      hour: 8,
      minute: 0,
      visual: 'vitamin',
    );

    expect(isDuplicateMedicationSchedule(duplicate, sampleSchedules), isTrue);
  });

  test('previous-day pending medicine becomes missed on next load', () async {
    final yesterday = MedicationController.dateOnly(
      DateTime.now(),
    ).subtract(const Duration(days: 1));
    final repository = _FakeMedicationRepository(
      <MedicationSchedule>[sampleSchedules.first],
      records: <MedicationRecord>[
        MedicationRecord(
          medicationId: sampleSchedules.first.id,
          scheduledAt: MedicationController.scheduledDateTime(
            sampleSchedules.first,
            yesterday,
          ),
          status: MedicationStatus.pending,
          scheduleSnapshot: sampleSchedules.first,
        ),
      ],
    );
    final controller = MedicationController(
      storageScope: 'elderly-id',
      repository: repository,
    );

    await controller.load();

    final previous = controller.records.firstWhere(
      (record) =>
          MedicationController.dateOnly(record.scheduledAt) == yesterday,
    );
    expect(previous.status, MedicationStatus.missed);
  });

  test('medication photo reference is stored without a public URL', () {
    const schedule = MedicationSchedule(
      id: 'metformin_photo',
      name: 'Metformin',
      dose: '500 mg',
      instruction: 'After meal',
      category: 'Prescription',
      hour: 20,
      minute: 0,
      visual: 'tablet',
      elderlyId: 'elderly-id',
      imageKey: 'elderly-id/caregiver-id/private-image.jpg',
    );

    final data = schedule.toFirestore('elderly-id');
    expect(data['imageKey'], schedule.imageKey);
    expect(data.containsKey('imageUrl'), isFalse);

    final restored = MedicationSchedule.fromFirestore(data);
    expect(restored.elderlyId, 'elderly-id');
    expect(restored.imageKey, schedule.imageKey);
  });

  test('medicine image upload sends an accepted MIME type', () {
    expect(medicationImageUserAgent, 'SHCA-Mobile/1.0');
    expect(
      medicationImageContentType(
        declaredType: 'application/octet-stream',
        filename: 'medicine.jpg',
      ),
      'image/jpeg',
    );
    expect(
      medicationImageContentType(
        declaredType: null,
        filename: 'camera-image',
        bytes: Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0]),
      ),
      'image/png',
    );
  });

  test('OCR text creates editable medicine suggestions', () {
    const packageText = '''
METFORMIN
500 mg tablets
Take after meal
Klinik Example
''';
    final suggestions = medicationSuggestionsFromText(packageText);

    expect(suggestions.name, 'METFORMIN');
    expect(suggestions.dose, '500 mg');
    expect(suggestions.instruction, 'After Meal');
    expect(suggestions.visual, 'tablet');
  });

  test('clinic label instructions cannot replace the medicine name', () {
    const packageText = '''
KLINIK MESRA
300Y-1 Ground Floor, Jalan Relau, Taman Desaria
Sungai Ara, 11900 Penang Tel: 04-6463185
Nama: Example Patient
Tarikh: 23 Mei 2026
Makan / Minum
1 KALI SEHARI
Sebelum / Selepas Makan
ANTI-CHOLESTROL RM
GONCANG SEBELUM MINUM
Controlled Medicine
''';
    final suggestions = medicationSuggestionsFromText(packageText);

    expect(suggestions.name, 'ANTI-CHOLESTROL');
    expect(suggestions.name, isNot(contains('Makan')));
  });

  test(
    'OCR confusion in the photographed label is corrected conservatively',
    () {
      const packageText = '''
KLINIK MESRA
Makan / Minum
ANTI- CHOLE\$7RO RM
GONCANG SEBELUM MINUM
Controlled Medicine
''';

      final suggestions = medicationSuggestionsFromText(packageText);

      expect(suggestions.name, 'ANTI-CHOLESTROL');
    },
  );

  test('Nama Ubat field is preferred over controlled medicine footer', () {
    const packageText = '''
Georgetown Pharmacy
Realcare Pharmacy (K) Sdn Bhd
35-1-30 Golden Triangle 2 Commercial Square
Nama:
Tarikh:
1 Biji / Pill
1 Kali Sehari / times a day
Sebelum Makan / Before Food
Nama Ubat:
Indikasi:
Neurontin
补肾
UBAT TERKAWAL / CONTROLLED MEDICINE / 管制药物
''';

    final suggestions = medicationSuggestionsFromText(packageText);

    expect(suggestions.name, 'Neurontin');
    expect(suggestions.name, isNot(contains('CONTROLLED')));
    expect(suggestions.name, isNot(contains('TERKAWAL')));
    expect(suggestions.dose, '1 Biji');
    expect(suggestions.quantity, 1);
    expect(suggestions.instruction, 'Before Food; Once Daily');
  });

  test('inline medicine-name labels work across common wording', () {
    expect(
      medicationSuggestionsFromText(
        'Medicine Name: Panadol\n500 mg\nAfter food',
      ).name,
      'Panadol',
    );
    expect(
      medicationSuggestionsFromText(
        'Nama Ubat - Metformin\nControlled Medicine',
      ).name,
      'Metformin',
    );
  });

  test('controlled medicine warning is never used as a medicine name', () {
    final suggestions = medicationSuggestionsFromText(
      'Georgetown Pharmacy\nUBAT TERKAWAL / CONTROLLED MEDICINE',
    );

    expect(suggestions.name, isNull);
  });

  test('uncertain administrative scan does not invent a medicine name', () {
    final suggestions = medicationSuggestionsFromText(
      'Klinik Example\nNama: Patient\nTarikh: 10 June 2026\nMakan / Minum',
    );

    expect(suggestions.name, isNull);
  });

  test('liquid OCR text selects the liquid fallback image type', () {
    final suggestions = medicationSuggestionsFromText(
      'COUGH SYRUP\n5 ml\nTake after food',
    );

    expect(suggestions.visual, 'liquid');
    expect(suggestions.category, 'Liquid medicine');
  });

  testWidgets('elderly can mark a pending medication as taken', (tester) async {
    final controller = MedicationController.preview(
      now: DateTime(2026, 8, 25, 9),
      schedules: sampleSchedules,
    );
    await tester.pumpWidget(
      MaterialApp(
        routes: <String, WidgetBuilder>{
          '/home': (_) => const Scaffold(body: Text('Home')),
        },
        home: MedicationReminderScreen(controller: controller),
      ),
    );
    await tester.pump();

    expect(find.text('Medication Reminder'), findsOneWidget);
    expect(find.text('Blood Pressure'), findsOneWidget);
    expect(
      find.byKey(const Key('medication-image-blood_pressure')),
      findsOneWidget,
    );
    await tester.ensureVisible(find.byKey(const Key('take-blood_pressure')));
    await tester.tap(find.byKey(const Key('take-blood_pressure')));
    await tester.pump();

    expect(
      controller.recordFor(sampleSchedules[1]).status,
      MedicationStatus.taken,
    );
  });

  testWidgets('medication history opens from the reminder page', (
    tester,
  ) async {
    final controller = MedicationController.preview(schedules: sampleSchedules);
    await tester.pumpWidget(
      MaterialApp(home: MedicationReminderScreen(controller: controller)),
    );

    await tester.ensureVisible(
      find.byKey(const Key('view-medication-history')),
    );
    await tester.tap(find.byKey(const Key('view-medication-history')));
    await tester.pumpAndSettle();

    expect(find.text('Medication History'), findsOneWidget);
    expect(find.text('Medication Records'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Week'), findsOneWidget);
    expect(find.text('Month'), findsOneWidget);
  });

  testWidgets('medication alert provides taken, snooze, and skip actions', (
    tester,
  ) async {
    final controller = MedicationController.preview(
      schedules: <MedicationSchedule>[sampleSchedules.first],
    );
    await tester.pumpWidget(
      MaterialApp(
        routes: <String, WidgetBuilder>{
          '/home': (_) => const Scaffold(body: Text('Home')),
        },
        home: MedicationAlertScreen(
          elderlyId: 'elderly-id',
          medicationId: sampleSchedules.first.id,
          controller: controller,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Medication Alert'), findsOneWidget);
    expect(find.text('Time to Take Medicine'), findsOneWidget);
    expect(find.text('Vitamin D'), findsOneWidget);
    expect(find.text('Taken'), findsOneWidget);
    expect(find.text('Snooze 10 min'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);

    await tester.tap(find.byKey(const Key('alert-taken')));
    await tester.pumpAndSettle();
    expect(
      controller.recordFor(sampleSchedules.first).status,
      MedicationStatus.taken,
    );
  });

  for (final action in ['taken', 'snooze', 'skip', 'back']) {
    testWidgets('alarm feedback starts and stops for $action', (tester) async {
      const channel = MethodChannel('com.shca.shca/alarm_permissions');
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return null;
      });
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      });
      final controller = MedicationController.preview(
        schedules: <MedicationSchedule>[sampleSchedules.first],
      );
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('Home')),
        ),
      );
      navigator.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => MedicationAlertScreen(
            elderlyId: 'elderly-id',
            medicationId: sampleSchedules.first.id,
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final starts = calls.where(
        (call) => call.method == 'startMedicationAlarmFeedback',
      );
      expect(starts.length, 1);
      final key = (starts.single.arguments as Map)['alarmKey'];
      expect(key, isNotEmpty);
      if (action == 'back') {
        navigator.currentState!.pop();
      } else {
        final button = find.byKey(Key('alert-$action'));
        await tester.ensureVisible(button);
        await tester.tap(button);
      }
      await tester.pumpAndSettle();
      expect(
        calls.any(
          (call) =>
              call.method == 'stopMedicationAlarmFeedback' &&
              (call.arguments as Map)['alarmKey'] == key,
        ),
        isTrue,
      );
      expect(find.text('Home'), findsOneWidget);
      expect(
        calls
            .where((call) => call.method == 'startMedicationAlarmFeedback')
            .length,
        1,
      );
    });
  }

  for (final stillActive in [true, false]) {
    testWidgets(
      'alarm renders immediately then checks active=$stillActive medicine',
      (tester) async {
        final ready = Completer<void>();
        final initial = sampleSchedules.first;
        final latest = MedicationSchedule.fromRecordSnapshot(
          medicationId: initial.id,
          scheduledAt: DateTime.now(),
          data: {
            ...initial.toRecordSnapshot(),
            'name': 'Updated medicine name',
          },
        );
        final repository = _DelayedMedicationRepository(
          ready.future,
          stillActive ? [latest] : [],
          records: [
            MedicationRecord(
              medicationId: initial.id,
              scheduledAt: DateTime.now(),
              status: MedicationStatus.pending,
              scheduleSnapshot: latest,
            ),
          ],
        );
        final controller = MedicationController(
          storageScope: 'elderly-id',
          repository: repository,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: MedicationAlertScreen(
              elderlyId: 'elderly-id',
              medicationId: initial.id,
              initialMedication: initial,
              controller: controller,
            ),
          ),
        );
        await tester.pump();
        expect(find.text(initial.name), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        final taken = find.descendant(
          of: find.byKey(const Key('alert-taken')),
          matching: find.byType(FilledButton),
        );
        expect(tester.widget<FilledButton>(taken).onPressed, isNull);
        ready.complete();
        await tester.pumpAndSettle();
        expect(find.text(initial.name), findsNothing);
        if (stillActive) {
          expect(find.text('Updated medicine name'), findsOneWidget);
          expect(tester.widget<FilledButton>(taken).onPressed, isNotNull);
        } else {
          expect(
            find.text('This medication is no longer available.'),
            findsOneWidget,
          );
        }
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
    );
  }

  testWidgets('medication alert displays the real recurrence', (tester) async {
    final schedule = MedicationSchedule(
      id: 'weekly',
      name: 'Weekly medicine',
      dose: '1 tablet',
      instruction: 'After meal',
      category: 'Other',
      hour: 9,
      minute: 0,
      visual: 'tablet',
      recurrence: MedicationRecurrence.selectedDays,
      weekdays: <int>[DateTime.monday, DateTime.friday],
    );
    final controller = MedicationController.preview(
      schedules: <MedicationSchedule>[schedule],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MedicationAlertScreen(
          elderlyId: 'elderly-id',
          medicationId: schedule.id,
          controller: controller,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Mon, Fri'), findsOneWidget);
    expect(find.text('Daily Reminder'), findsNothing);
  });

  testWidgets('snoozed medication alert displays the new reminder time', (
    tester,
  ) async {
    final controller = MedicationController.preview(
      schedules: <MedicationSchedule>[sampleSchedules.first],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MedicationAlertScreen(
          elderlyId: 'elderly-id',
          medicationId: sampleSchedules.first.id,
          scheduledAt: DateTime(2026, 10, 21, 0, 22),
          reminderAt: DateTime(2026, 10, 21, 0, 32),
          controller: controller,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Reminder time: 12:32 AM'), findsOneWidget);
    expect(find.textContaining('12:22 AM'), findsNothing);
  });

  testWidgets('caregiver add form shows clear photo controls', (tester) async {
    final repository = _FakeMedicationRepository(<MedicationSchedule>[]);
    await tester.pumpWidget(
      MaterialApp(
        home: CaregiverMedicationScheduleScreen(
          elderly: _linkedElderly,
          repository: repository,
          caregiverId: 'caregiver-id',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add-medication')));
    await tester.pumpAndSettle();

    expect(find.text('Add Medication'), findsOneWidget);
    expect(find.text('Medicine image'), findsOneWidget);
    expect(find.byKey(const Key('scan-medication-package')), findsOneWidget);
    expect(find.byKey(const Key('take-medication-photo')), findsOneWidget);
    expect(find.byKey(const Key('choose-medication-photo')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('medication-repeat-type')));
    expect(find.byKey(const Key('medication-start-date')), findsOneWidget);
    expect(find.byKey(const Key('medication-duration')), findsOneWidget);
    expect(find.text('Ongoing / until stopped'), findsOneWidget);
    expect(find.byKey(const Key('medication-end-date')), findsNothing);
  });

  testWidgets('caregiver can add separate times for multiple daily doses', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _FakeMedicationRepository(<MedicationSchedule>[]);
    await tester.pumpWidget(
      MaterialApp(
        home: CaregiverMedicationScheduleScreen(
          elderly: _linkedElderly,
          repository: repository,
          caregiverId: 'caregiver-id',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add-medication')));
    await tester.pumpAndSettle();
    final countField = find.byKey(const Key('medication-times-per-day'));
    await tester.ensureVisible(countField);
    await tester.tap(countField);
    await tester.pumpAndSettle();
    await tester.tap(find.text('3 times per day').last);
    await tester.pumpAndSettle();

    expect(find.text('Dose 1 time'), findsOneWidget);
    expect(find.text('Dose 2 time'), findsOneWidget);
    expect(find.text('Dose 3 time'), findsOneWidget);
    expect(find.byKey(const Key('change-medication-time-1')), findsOneWidget);
    expect(find.byKey(const Key('change-medication-time-2')), findsOneWidget);
  });

  testWidgets('caregiver can switch elderly medication records', (
    tester,
  ) async {
    final repository = _FakeMedicationRepository(<MedicationSchedule>[]);
    await tester.pumpWidget(
      MaterialApp(
        home: CaregiverMedicationScheduleScreen(
          elderly: _linkedElderly,
          linkedElderly: const <LinkedElderly>[
            _linkedElderly,
            _secondLinkedElderly,
          ],
          repository: repository,
          caregiverId: 'caregiver-id',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(repository.loadedScheduleElderlyIds.last, 'elderly-id');
    expect(repository.loadedRecordElderlyIds.last, 'elderly-id');

    await tester.tap(find.byKey(const Key('caregiver-elderly-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mary Lim').last);
    await tester.pumpAndSettle();

    expect(repository.loadedScheduleElderlyIds.last, 'elderly-id-2');
    expect(repository.loadedRecordElderlyIds.last, 'elderly-id-2');
    expect(find.text('Mary Lim'), findsWidgets);
  });

  testWidgets('save guidance stays visible inside the medication form', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _FakeMedicationRepository(<MedicationSchedule>[]);
    await tester.pumpWidget(
      MaterialApp(
        home: CaregiverMedicationScheduleScreen(
          elderly: _linkedElderly,
          repository: repository,
          caregiverId: 'caregiver-id',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add-medication')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('save-medication')));
    await tester.tap(find.byKey(const Key('save-medication')));
    await tester.pump();

    expect(find.byKey(const Key('medication-form-message')), findsOneWidget);
    expect(
      find.textContaining(
        'medicine name, instruction source, instruction, the safety confirmation',
      ),
      findsOneWidget,
    );
    expect(find.text('Add Medication'), findsOneWidget);
  });

  testWidgets('caregiver can reopen a saved medication for editing', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _FakeMedicationRepository(<MedicationSchedule>[
      const MedicationSchedule(
        id: 'editable-medication',
        name: 'Metformin',
        dose: '500 mg',
        instruction: 'After meal',
        category: 'Diabetes',
        hour: 20,
        minute: 0,
        visual: 'tablet',
        elderlyId: 'elderly-id',
        instructionSource: 'Doctor prescription',
        sourceConfirmed: true,
        quantity: 2,
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: CaregiverMedicationScheduleScreen(
          elderly: _linkedElderly,
          repository: repository,
          caregiverId: 'caregiver-id',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('edit-medication-editable-medication')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Edit Medication'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Metformin'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('change-medication-time')),
        matching: find.text('8:00 PM'),
      ),
      findsOneWidget,
    );
    expect(find.text('Save Changes'), findsOneWidget);
    expect(find.text('2 tablets'), findsOneWidget);
    expect(find.byKey(const Key('medication-strength-unit')), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('medication-duration')));
    await tester.tap(find.byKey(const Key('medication-duration')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('7 days').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Ends '), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const Key('increase-medication-quantity')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('increase-medication-quantity')));
    await tester.pump();
    expect(find.text('3 tablets'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('medication-name')),
      'Metformin XR',
    );
    await tester.enterText(find.byKey(const Key('medication-dose')), '750');
    await tester.enterText(
      find.byKey(const Key('medication-low-stock-threshold')),
      '5',
    );
    await tester.ensureVisible(find.byKey(const Key('save-medication')));
    await tester.tap(find.byKey(const Key('save-medication')));
    await tester.pumpAndSettle();

    expect(repository.schedules, hasLength(1));
    expect(repository.schedules.single.id, 'editable-medication');
    expect(repository.schedules.single.name, 'Metformin XR');
    expect(repository.schedules.single.effectiveQuantity, 3);
    expect(repository.schedules.single.dose, '750 mg');
    expect(repository.schedules.single.doseSummary, '750 mg • 3 tablets');
    expect(repository.schedules.single.lowStockThreshold, 5);
    expect(
      repository.schedules.single.endDate!
          .difference(repository.schedules.single.startDate!)
          .inDays,
      6,
    );
    expect(find.text('Metformin XR'), findsOneWidget);
  });

  testWidgets('caregiver can delete an active medication schedule', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _FakeMedicationRepository(
      List<MedicationSchedule>.of(sampleSchedules),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CaregiverMedicationScheduleScreen(
          elderly: _linkedElderly,
          repository: repository,
          caregiverId: 'caregiver-id',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final deleteButton = find.byKey(const Key('delete-medication-vitamin_d'));
    await tester.ensureVisible(deleteButton);
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();

    expect(find.text('Delete medication reminder?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-delete-medication')));
    await tester.pumpAndSettle();

    expect(
      repository.schedules.any((schedule) => schedule.id == 'vitamin_d'),
      isFalse,
    );
    expect(find.byKey(const Key('delete-medication-vitamin_d')), findsNothing);
  });

  testWidgets(
    'caregiver filters medicines by category without duplicate heading',
    (tester) async {
      final repository = _FakeMedicationRepository(
        List<MedicationSchedule>.of(sampleSchedules),
      );
      await tester.binding.setSurfaceSize(const Size(430, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: CaregiverMedicationScheduleScreen(
            elderly: _linkedElderly,
            repository: repository,
            caregiverId: 'caregiver-id',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Manage Current Schedules'), findsNothing);
      await tester.tap(find.byKey(const Key('caregiver-category-filter')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, 'Diabetes'),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('active-category-filter')), findsOneWidget);
      expect(
        find.byKey(const Key('edit-medication-metformin')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('edit-medication-vitamin_d')), findsNothing);
    },
  );

  testWidgets('low-stock banner identifies affected medicine', (tester) async {
    final repository = _FakeMedicationRepository(<MedicationSchedule>[
      const MedicationSchedule(
        id: 'low-stock-panadol',
        name: 'Panadol',
        dose: '1 tablet',
        instruction: 'After meal',
        category: 'Pain relief',
        hour: 8,
        minute: 0,
        visual: 'tablet',
        stockRemaining: 2,
      ),
    ]);
    await tester.binding.setSurfaceSize(const Size(430, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: CaregiverMedicationScheduleScreen(
          elderly: _linkedElderly,
          repository: repository,
          caregiverId: 'caregiver-id',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Panadol • Tap to view'), findsOneWidget);
    await tester.tap(find.byKey(const Key('caregiver-low-stock-banner')));
    await tester.pumpAndSettle();

    expect(find.text('Medicines running low'), findsOneWidget);
    expect(find.text('2 left • Alert at 3'), findsOneWidget);
    expect(
      find.byKey(const Key('low-stock-low-stock-panadol')),
      findsOneWidget,
    );
  });

  testWidgets('caregiver records support search, status, and three-day view', (
    tester,
  ) async {
    final today = MedicationController.dateOnly(DateTime.now());
    final repository = _FakeMedicationRepository(
      List<MedicationSchedule>.of(sampleSchedules),
      records: <MedicationRecord>[
        MedicationRecord(
          medicationId: 'vitamin_d',
          scheduledAt: MedicationController.scheduledDateTime(
            sampleSchedules[0],
            today,
          ),
          status: MedicationStatus.taken,
          actionAt: MedicationController.scheduledDateTime(
            sampleSchedules[0],
            today,
          ).add(const Duration(minutes: 2)),
        ),
        MedicationRecord(
          medicationId: 'metformin',
          scheduledAt: MedicationController.scheduledDateTime(
            sampleSchedules[2],
            today,
          ),
          status: MedicationStatus.pending,
        ),
      ],
    );
    await tester.binding.setSurfaceSize(const Size(430, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: CaregiverMedicationScheduleScreen(
          elderly: _linkedElderly,
          repository: repository,
          caregiverId: 'caregiver-id',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('3 days'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('caregiver-medication-search')),
      'Metformin',
    );
    await tester.pump();

    expect(find.textContaining('Metformin ·'), findsOneWidget);
    expect(find.textContaining('Vitamin D ·'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Taken'));
    await tester.pump();
    expect(find.textContaining('Metformin ·'), findsNothing);
    expect(
      find.text('No matching medication records for this day.'),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('week history keeps records for removed medication schedules', (
    tester,
  ) async {
    final now = DateTime.now();
    final controller = MedicationController.preview(
      now: now,
      schedules: sampleSchedules,
      records: <MedicationRecord>[
        MedicationRecord(
          medicationId: 'removed_medication',
          scheduledAt: now.subtract(const Duration(days: 2)),
          status: MedicationStatus.taken,
          actionAt: now.subtract(const Duration(days: 2)),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(home: MedicationHistoryScreen(controller: controller)),
    );
    await tester.tap(find.text('Week'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Archived medication'), findsOneWidget);
    expect(find.textContaining('No longer active'), findsOneWidget);
  });
}
