import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum MedicationStatus { pending, taken, snoozed, missed }

enum MedicationRecurrence {
  daily,
  selectedDays,
  intervalDays,
  oneTime,
  asNeeded,
}

/// Lets an already-open medication page reload after a separate alarm screen
/// changes a record. The elderly and alarm screens use different controllers.
class MedicationRecordRefresh {
  MedicationRecordRefresh._();

  static final StreamController<String> _controller =
      StreamController<String>.broadcast(sync: true);

  static Stream<String> get events => _controller.stream;

  static void notify(String elderlyId) => _controller.add(elderlyId);
}

const Set<String> _legacyDemoScheduleKeys = <String>{
  'vitamin_d',
  'blood_pressure',
  'metformin',
};

bool isLegacyDemoMedicationData(Map<String, dynamic> data) {
  final scheduleKey = data['scheduleKey'] as String?;
  return _legacyDemoScheduleKeys.contains(scheduleKey);
}

@visibleForTesting
int? medicationStockAfterTakenDose(int? remaining, int quantity) {
  if (remaining == null) return null;
  return (remaining - quantity.clamp(1, 99)).clamp(0, 1 << 30).toInt();
}

class MedicationSchedule {
  const MedicationSchedule({
    required this.id,
    required this.name,
    required this.dose,
    required this.instruction,
    required this.category,
    required this.hour,
    required this.minute,
    required this.visual,
    this.elderlyId = '',
    this.imageKey = '',
    this.instructionSource = 'Not specified',
    this.sourceConfirmed = false,
    this.quantity,
    this.stockRemaining,
    this.lowStockThreshold = 3,
    this.recurrence = MedicationRecurrence.daily,
    this.startDate,
    this.endDate,
    this.weekdays = const <int>[],
    this.intervalDays = 1,
    this.reminderMinutes = const <int>[],
  });

  final String id;
  final String name;
  final String dose;
  final String instruction;
  final String category;
  final int hour;
  final int minute;
  final String visual;
  final String elderlyId;
  final String imageKey;
  final String instructionSource;
  final bool sourceConfirmed;
  final int? quantity;
  final int? stockRemaining;
  final int lowStockThreshold;
  final MedicationRecurrence recurrence;
  final DateTime? startDate;
  final DateTime? endDate;
  final List<int> weekdays;
  final int intervalDays;
  final List<int> reminderMinutes;

  /// Minutes after midnight for every dose due on a scheduled day.
  /// Older schedules fall back to the original hour and minute fields.
  List<int> get dailyReminderMinutes {
    final values = <int>{hour * 60 + minute};
    values.addAll(reminderMinutes.where((value) => value >= 0 && value < 1440));
    return values.toList()..sort();
  }

  int get timesPerDay => dailyReminderMinutes.length;

  int get effectiveQuantity =>
      quantity ?? medicationQuantityFromText(dose) ?? 1;

  String get quantityLabel {
    final amount = effectiveQuantity;
    final singularUnit = switch (visual) {
      'capsule' => 'capsule',
      'liquid' => 'dose',
      _ => 'tablet',
    };
    return '$amount $singularUnit${amount == 1 ? '' : 's'}';
  }

  String get doseSummary {
    final strength = medicationStrengthFromText(dose);
    return strength.isEmpty ? quantityLabel : '$strength • $quantityLabel';
  }

  bool get isLowStock =>
      stockRemaining != null && stockRemaining! <= lowStockThreshold;

  bool get hasAutomaticReminder => recurrence != MedicationRecurrence.asNeeded;

  bool isScheduledOn(DateTime value) {
    final date = MedicationController.dateOnly(value);
    final start = startDate == null
        ? null
        : MedicationController.dateOnly(startDate!);
    final end = endDate == null
        ? null
        : MedicationController.dateOnly(endDate!);
    if (start != null && date.isBefore(start)) return false;
    if (end != null && date.isAfter(end)) return false;

    return switch (recurrence) {
      MedicationRecurrence.daily => true,
      MedicationRecurrence.selectedDays => weekdays.contains(date.weekday),
      MedicationRecurrence.intervalDays =>
        start == null
            ? true
            : date.difference(start).inDays % intervalDays.clamp(1, 365) == 0,
      MedicationRecurrence.oneTime => start != null && date == start,
      MedicationRecurrence.asNeeded => false,
    };
  }

  String get scheduleSummary => switch (recurrence) {
    MedicationRecurrence.daily => 'Every day',
    MedicationRecurrence.selectedDays =>
      weekdays.isEmpty
          ? 'Selected days'
          : weekdays.map(_shortWeekday).join(', '),
    MedicationRecurrence.intervalDays =>
      intervalDays <= 1 ? 'Every day' : 'Every $intervalDays days',
    MedicationRecurrence.oneTime =>
      startDate == null ? 'One time' : 'One time • ${_shortDate(startDate!)}',
    MedicationRecurrence.asNeeded => 'As needed • No automatic alarm',
  };

  String get treatmentDurationSummary {
    if (recurrence == MedicationRecurrence.oneTime) {
      return startDate == null
          ? 'One-day treatment'
          : 'One dose • ${_shortDate(startDate!)}';
    }
    if (startDate == null && endDate == null) return 'Ongoing treatment';
    if (endDate == null) {
      return startDate == null
          ? 'Ongoing treatment'
          : 'From ${_shortDate(startDate!)} • Until stopped';
    }
    if (startDate == null) return 'Until ${_shortDate(endDate!)}';
    final days =
        MedicationController.dateOnly(
          endDate!,
        ).difference(MedicationController.dateOnly(startDate!)).inDays +
        1;
    return '$days-day treatment • ${_shortDate(startDate!)}–${_shortDate(endDate!)}';
  }

  MedicationSchedule copyWithStockRemaining(int? value) => MedicationSchedule(
    id: id,
    name: name,
    dose: dose,
    instruction: instruction,
    category: category,
    hour: hour,
    minute: minute,
    visual: visual,
    elderlyId: elderlyId,
    imageKey: imageKey,
    instructionSource: instructionSource,
    sourceConfirmed: sourceConfirmed,
    quantity: quantity,
    stockRemaining: value,
    lowStockThreshold: lowStockThreshold,
    recurrence: recurrence,
    startDate: startDate,
    endDate: endDate,
    weekdays: weekdays,
    intervalDays: intervalDays,
    reminderMinutes: reminderMinutes,
  );

  Map<String, dynamic> toFirestore(String elderlyId) => <String, dynamic>{
    'elderlyId': elderlyId,
    'scheduleKey': id,
    'name': name,
    'dose': dose,
    'instruction': instruction,
    'category': category,
    'hour': hour,
    'minute': minute,
    'visual': visual,
    'imageKey': imageKey,
    'instructionSource': instructionSource,
    'sourceConfirmed': sourceConfirmed,
    'quantity': effectiveQuantity,
    'stockRemaining': stockRemaining,
    'lowStockThreshold': lowStockThreshold,
    'recurrence': recurrence.name,
    'startDate': startDate == null ? null : Timestamp.fromDate(startDate!),
    'endDate': endDate == null ? null : Timestamp.fromDate(endDate!),
    'weekdays': weekdays,
    'intervalDays': intervalDays,
    'reminderMinutes': dailyReminderMinutes,
    'active': true,
  };

  Map<String, dynamic> toRecordSnapshot() => <String, dynamic>{
    'name': name,
    'dose': dose,
    'quantity': effectiveQuantity,
    'instruction': instruction,
    'category': category,
    'visual': visual,
    'imageKey': imageKey,
    'instructionSource': instructionSource,
    'recurrence': recurrence.name,
    'startDate': startDate?.toIso8601String(),
    'endDate': endDate?.toIso8601String(),
    'weekdays': weekdays,
    'intervalDays': intervalDays,
    'reminderMinutes': dailyReminderMinutes,
  };

  factory MedicationSchedule.fromRecordSnapshot({
    required String medicationId,
    required DateTime scheduledAt,
    required Map<String, dynamic> data,
  }) {
    return MedicationSchedule(
      id: medicationId,
      name: (data['name'] as String?) ?? 'Medication',
      dose: (data['dose'] as String?) ?? '',
      instruction: (data['instruction'] as String?) ?? '',
      category: (data['category'] as String?) ?? '',
      hour: scheduledAt.hour,
      minute: scheduledAt.minute,
      visual: (data['visual'] as String?) ?? 'tablet',
      imageKey: (data['imageKey'] as String?) ?? '',
      instructionSource:
          (data['instructionSource'] as String?) ?? 'Not specified',
      quantity: (data['quantity'] as num?)?.toInt(),
      recurrence: _parseRecurrence(data['recurrence']),
      startDate: _parseDate(data['startDate']),
      endDate: _parseDate(data['endDate']),
      weekdays: _parseWeekdays(data['weekdays']),
      intervalDays: (data['intervalDays'] as num?)?.toInt() ?? 1,
      reminderMinutes: _parseReminderMinutes(data['reminderMinutes']),
    );
  }

  factory MedicationSchedule.fromFirestore(Map<String, dynamic> data) {
    return MedicationSchedule(
      id: (data['scheduleKey'] as String?) ?? '',
      name: (data['name'] as String?) ?? 'Medication',
      dose: (data['dose'] as String?) ?? '',
      instruction: (data['instruction'] as String?) ?? '',
      category: (data['category'] as String?) ?? '',
      hour: (data['hour'] as num?)?.toInt() ?? 8,
      minute: (data['minute'] as num?)?.toInt() ?? 0,
      visual: (data['visual'] as String?) ?? 'pill',
      elderlyId: (data['elderlyId'] as String?) ?? '',
      imageKey: (data['imageKey'] as String?) ?? '',
      instructionSource:
          (data['instructionSource'] as String?) ?? 'Not specified',
      sourceConfirmed: data['sourceConfirmed'] == true,
      quantity:
          (data['quantity'] as num?)?.toInt() ??
          medicationQuantityFromText(data['dose'] as String?),
      stockRemaining: (data['stockRemaining'] as num?)?.toInt(),
      lowStockThreshold: (data['lowStockThreshold'] as num?)?.toInt() ?? 3,
      recurrence: _parseRecurrence(data['recurrence']),
      startDate: _parseDate(data['startDate']),
      endDate: _parseDate(data['endDate']),
      weekdays: _parseWeekdays(data['weekdays']),
      intervalDays: (data['intervalDays'] as num?)?.toInt() ?? 1,
      reminderMinutes: _parseReminderMinutes(data['reminderMinutes']),
    );
  }
}

MedicationRecurrence _parseRecurrence(dynamic value) =>
    MedicationRecurrence.values.firstWhere(
      (item) => item.name == value,
      orElse: () => MedicationRecurrence.daily,
    );

List<int> _parseWeekdays(dynamic value) => value is List
    ? value
          .whereType<num>()
          .map((item) => item.toInt())
          .where((item) => item >= DateTime.monday && item <= DateTime.sunday)
          .toSet()
          .toList()
    : const <int>[];

List<int> _parseReminderMinutes(dynamic value) => value is List
    ? (value
          .whereType<num>()
          .map((item) => item.toInt())
          .where((item) => item >= 0 && item < 1440)
          .toSet()
          .toList()
        ..sort())
    : const <int>[];

String _shortWeekday(int weekday) => const <String>[
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
][weekday.clamp(DateTime.monday, DateTime.sunday) - 1];

String _shortDate(DateTime value) =>
    '${value.day}/${value.month}/${value.year}';

int? medicationQuantityFromText(String? value) {
  final match = RegExp(
    r'^\s*(\d+)\s*(?:tablet|tablets|capsule|capsules|dose|doses)\s*$',
    caseSensitive: false,
  ).firstMatch(value ?? '');
  return match == null ? null : int.tryParse(match.group(1)!);
}

String medicationStrengthFromText(String? value) =>
    medicationQuantityFromText(value) == null ? (value ?? '').trim() : '';

class MedicationRecord {
  const MedicationRecord({
    required this.medicationId,
    required this.scheduledAt,
    required this.status,
    this.actionAt,
    this.snoozedUntil,
    this.scheduleSnapshot,
  });

  final String medicationId;
  final DateTime scheduledAt;
  final MedicationStatus status;
  final DateTime? actionAt;
  final DateTime? snoozedUntil;
  final MedicationSchedule? scheduleSnapshot;

  String get key => MedicationController.recordKey(
    medicationId,
    scheduledAt,
    includeTime: (scheduleSnapshot?.timesPerDay ?? 1) > 1,
  );

  MedicationRecord copyWith({
    MedicationStatus? status,
    DateTime? actionAt,
    DateTime? snoozedUntil,
    bool clearSnooze = false,
    bool clearActionAt = false,
    MedicationSchedule? scheduleSnapshot,
  }) {
    return MedicationRecord(
      medicationId: medicationId,
      scheduledAt: scheduledAt,
      status: status ?? this.status,
      actionAt: clearActionAt ? null : actionAt ?? this.actionAt,
      snoozedUntil: clearSnooze ? null : snoozedUntil ?? this.snoozedUntil,
      scheduleSnapshot: scheduleSnapshot ?? this.scheduleSnapshot,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'medicationId': medicationId,
    'scheduledAt': scheduledAt.toIso8601String(),
    'status': status.name,
    'actionAt': actionAt?.toIso8601String(),
    'snoozedUntil': snoozedUntil?.toIso8601String(),
    'scheduleSnapshot': scheduleSnapshot?.toRecordSnapshot(),
  };

  Map<String, dynamic> toFirestore(String elderlyId) => <String, dynamic>{
    'elderlyId': elderlyId,
    'medicationId': medicationId,
    'scheduledAt': Timestamp.fromDate(scheduledAt),
    'status': status.name,
    'actionAt': actionAt == null ? null : Timestamp.fromDate(actionAt!),
    'snoozedUntil': snoozedUntil == null
        ? null
        : Timestamp.fromDate(snoozedUntil!),
    'recordKey': key,
    'scheduleSnapshot': scheduleSnapshot?.toRecordSnapshot(),
  };

  factory MedicationRecord.fromJson(Map<String, dynamic> json) {
    return MedicationRecord(
      medicationId: json['medicationId'] as String,
      scheduledAt: DateTime.parse(json['scheduledAt'] as String),
      status: _parseMedicationStatus(json['status']),
      actionAt: _parseDate(json['actionAt']),
      snoozedUntil: _parseDate(json['snoozedUntil']),
      scheduleSnapshot: _scheduleSnapshotFromData(
        medicationId: json['medicationId'] as String,
        scheduledAt: DateTime.parse(json['scheduledAt'] as String),
        value: json['scheduleSnapshot'],
      ),
    );
  }

  factory MedicationRecord.fromFirestore(Map<String, dynamic> data) {
    final medicationId = (data['medicationId'] as String?) ?? '';
    final scheduledAt = _parseDate(data['scheduledAt']) ?? DateTime.now();
    return MedicationRecord(
      medicationId: medicationId,
      scheduledAt: scheduledAt,
      status: _parseMedicationStatus(data['status']),
      actionAt: _parseDate(data['actionAt']),
      snoozedUntil: _parseDate(data['snoozedUntil']),
      scheduleSnapshot: _scheduleSnapshotFromData(
        medicationId: medicationId,
        scheduledAt: scheduledAt,
        value: data['scheduleSnapshot'],
      ),
    );
  }
}

MedicationSchedule? _scheduleSnapshotFromData({
  required String medicationId,
  required DateTime scheduledAt,
  required dynamic value,
}) {
  if (value is! Map) return null;
  return MedicationSchedule.fromRecordSnapshot(
    medicationId: medicationId,
    scheduledAt: scheduledAt,
    data: Map<String, dynamic>.from(value),
  );
}

List<MedicationRecord> deduplicateMedicationRecords(
  Iterable<MedicationRecord> records,
) {
  final unique = <String, MedicationRecord>{};
  for (final record in records) {
    final existing = unique[record.key];
    if (existing == null) {
      unique[record.key] = record;
      continue;
    }
    final preferred = _preferMedicationRecord(existing, record);
    final fallback = identical(preferred, existing) ? record : existing;
    unique[record.key] =
        preferred.scheduleSnapshot == null && fallback.scheduleSnapshot != null
        ? preferred.copyWith(scheduleSnapshot: fallback.scheduleSnapshot)
        : preferred;
  }
  return unique.values.toList();
}

MedicationRecord _preferMedicationRecord(
  MedicationRecord first,
  MedicationRecord second,
) {
  final firstAction = first.actionAt?.millisecondsSinceEpoch ?? -1;
  final secondAction = second.actionAt?.millisecondsSinceEpoch ?? -1;
  if (firstAction != secondAction) {
    return firstAction > secondAction ? first : second;
  }
  int statusPriority(MedicationStatus status) => switch (status) {
    MedicationStatus.taken => 4,
    MedicationStatus.missed => 3,
    MedicationStatus.snoozed => 2,
    MedicationStatus.pending => 1,
  };
  return statusPriority(first.status) >= statusPriority(second.status)
      ? first
      : second;
}

MedicationStatus _parseMedicationStatus(dynamic value) =>
    MedicationStatus.values.firstWhere(
      (status) => status.name == value,
      orElse: () => MedicationStatus.pending,
    );

DateTime? _parseDate(dynamic value) {
  if (value is Timestamp) return value.toDate();
  if (value is String && value.isNotEmpty) return DateTime.tryParse(value);
  return null;
}

abstract interface class MedicationRepository {
  Future<List<MedicationSchedule>> loadSchedules(String elderlyId);

  Future<void> saveSchedules(
    String elderlyId,
    List<MedicationSchedule> schedules, {
    String? createdByCaregiverId,
    bool schedulesAreNew = false,
  });

  Future<void> deleteSchedule(String elderlyId, String scheduleId);

  Future<List<MedicationRecord>> loadRecords(String elderlyId);

  Future<void> saveRecord(String elderlyId, MedicationRecord record);
}

class FirestoreMedicationRepository implements MedicationRepository {
  FirestoreMedicationRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _medications =>
      _firestore.collection('medications');

  CollectionReference<Map<String, dynamic>> get _records =>
      _firestore.collection('medication_records');

  @override
  Future<List<MedicationSchedule>> loadSchedules(String elderlyId) async {
    final result = await _medications
        .where('elderlyId', isEqualTo: elderlyId)
        .get();
    final schedules = result.docs
        .where(
          (document) =>
              document.data()['active'] != false &&
              !isLegacyDemoMedicationData(document.data()),
        )
        .map((document) => MedicationSchedule.fromFirestore(document.data()))
        .where((schedule) => schedule.id.isNotEmpty)
        .toList();
    schedules.sort((first, second) {
      final firstMinutes = first.hour * 60 + first.minute;
      final secondMinutes = second.hour * 60 + second.minute;
      return firstMinutes.compareTo(secondMinutes);
    });
    return schedules;
  }

  @override
  Future<void> saveSchedules(
    String elderlyId,
    List<MedicationSchedule> schedules, {
    String? createdByCaregiverId,
    bool schedulesAreNew = false,
  }) async {
    for (final schedule in schedules) {
      final reference = _medications.doc('${elderlyId}_${schedule.id}');
      await reference.set(<String, dynamic>{
        ...schedule.toFirestore(elderlyId),
        if (schedulesAreNew) 'createdByCaregiverId': ?createdByCaregiverId,
        'updatedByCaregiverId': ?createdByCaregiverId,
        if (schedulesAreNew) 'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }
  }

  @override
  Future<void> deleteSchedule(String elderlyId, String scheduleId) async {
    await _medications.doc('${elderlyId}_$scheduleId').delete();
  }

  @override
  Future<List<MedicationRecord>> loadRecords(String elderlyId) async {
    final result = await _records
        .where('elderlyId', isEqualTo: elderlyId)
        .orderBy('scheduledAt', descending: true)
        .limit(400)
        .get();
    final records = deduplicateMedicationRecords(
      result.docs
          .map((document) => MedicationRecord.fromFirestore(document.data()))
          .where((record) => record.medicationId.isNotEmpty),
    );
    records.sort(
      (first, second) => second.scheduledAt.compareTo(first.scheduledAt),
    );
    return records;
  }

  @override
  Future<void> saveRecord(String elderlyId, MedicationRecord record) async {
    await _records.doc('${elderlyId}_${record.key}').set(<String, dynamic>{
      ...record.toFirestore(elderlyId),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Saves a taken dose and decrements stock exactly once for that occurrence.
  Future<int?> saveTakenRecordAndUpdateStock(
    String elderlyId,
    MedicationRecord record,
  ) async {
    final recordReference = _records.doc('${elderlyId}_${record.key}');
    final scheduleReference = _medications.doc(
      '${elderlyId}_${record.medicationId}',
    );
    return _firestore.runTransaction<int?>((transaction) async {
      final previous = await transaction.get(recordReference);
      final schedule = await transaction.get(scheduleReference);
      final wasAlreadyTaken = previous.data()?['status'] == 'taken';
      int? nextRemaining;
      if (!wasAlreadyTaken && schedule.exists) {
        final remaining = (schedule.data()?['stockRemaining'] as num?)?.toInt();
        final quantity =
            (schedule.data()?['quantity'] as num?)
                ?.toInt()
                .clamp(1, 99)
                .toInt() ??
            1;
        if (remaining != null) {
          nextRemaining = medicationStockAfterTakenDose(remaining, quantity);
          transaction.update(scheduleReference, <String, dynamic>{
            'stockRemaining': nextRemaining,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      }
      transaction.set(recordReference, <String, dynamic>{
        ...record.toFirestore(elderlyId),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return nextRemaining;
    });
  }
}

class MedicationController extends ChangeNotifier {
  MedicationController({
    required String storageScope,
    MedicationRepository? repository,
  }) : _elderlyId = storageScope,
       _legacyStorageKey = 'medication_records_$storageScope',
       _repository = repository ?? FirestoreMedicationRepository();

  MedicationController.preview({
    DateTime? now,
    List<MedicationSchedule> schedules = const <MedicationSchedule>[],
    List<MedicationRecord>? records,
  }) : _elderlyId = 'preview',
       _legacyStorageKey = 'medication_preview',
       _repository = null {
    final reference = now ?? DateTime.now();
    _schedules = schedules.toList(growable: false);
    _records =
        records?.toList(growable: false) ??
        _createPreviewRecords(reference, _schedules);
    _isLoaded = true;
  }

  final String _elderlyId;
  final String _legacyStorageKey;
  final MedicationRepository? _repository;
  List<MedicationSchedule> _schedules = <MedicationSchedule>[];
  List<MedicationRecord> _records = <MedicationRecord>[];
  bool _isLoaded = false;

  bool get isLoaded => _isLoaded;
  List<MedicationSchedule> get medicationSchedules =>
      List.unmodifiable(_schedules);
  List<MedicationSchedule> schedulesForDate(DateTime date) => _schedules
      .where((medication) => medication.isScheduledOn(date))
      .toList(growable: false);
  List<MedicationSchedule> get asNeededMedications => _schedules
      .where(
        (medication) => medication.recurrence == MedicationRecurrence.asNeeded,
      )
      .toList(growable: false);
  List<MedicationRecord> get records => List.unmodifiable(_records);
  List<MedicationSchedule> get lowStockMedications => _schedules
      .where((medication) => medication.isLowStock)
      .toList(growable: false);

  Future<void> load() async {
    if (_isLoaded) return;
    final repository = _repository;
    if (repository == null) return;

    _schedules = await repository.loadSchedules(_elderlyId);

    _records = deduplicateMedicationRecords(
      await repository.loadRecords(_elderlyId),
    );
    if (_records.isEmpty) {
      _records = deduplicateMedicationRecords(await _loadLegacyRecords());
      if (_records.isNotEmpty) {
        for (final record in _records) {
          await repository.saveRecord(_elderlyId, record);
        }
      }
    }
    await _ensureRecordsForDate(DateTime.now(), persist: true);
    await _markPastPendingRecordsMissed();
    _isLoaded = true;
    notifyListeners();
  }

  Future<void> reload() async {
    _isLoaded = false;
    await load();
  }

  List<DateTime> occurrencesForDate(
    MedicationSchedule medication,
    DateTime date,
  ) {
    final targetDate = dateOnly(date);
    if (!medication.isScheduledOn(targetDate)) return const <DateTime>[];
    return medication.dailyReminderMinutes
        .map(
          (minutes) => DateTime(
            targetDate.year,
            targetDate.month,
            targetDate.day,
            minutes ~/ 60,
            minutes % 60,
          ),
        )
        .toList(growable: false);
  }

  List<MedicationRecord> recordsFor(
    MedicationSchedule medication, {
    DateTime? date,
  }) => occurrencesForDate(medication, date ?? DateTime.now())
      .map((occurrence) => recordFor(medication, scheduledAt: occurrence))
      .toList(growable: false);

  MedicationRecord recordFor(
    MedicationSchedule medication, {
    DateTime? date,
    DateTime? scheduledAt,
  }) {
    final targetDate = dateOnly(scheduledAt ?? date ?? DateTime.now());
    final occurrence = scheduledAt ?? scheduledDateTime(medication, targetDate);
    final targetKey = recordKeyFor(medication, occurrence);
    final record = _records.firstWhere(
      (record) => record.key == targetKey,
      orElse: () => MedicationRecord(
        medicationId: medication.id,
        scheduledAt: occurrence,
        status: MedicationStatus.pending,
        scheduleSnapshot: medication,
      ),
    );
    final aligned = _alignSingleDailyOccurrence(record, medication, occurrence);
    return aligned.scheduleSnapshot == null
        ? aligned.copyWith(scheduleSnapshot: medication)
        : aligned;
  }

  Future<void> markTaken(
    MedicationSchedule medication, {
    DateTime? scheduledAt,
  }) async {
    final record = recordFor(medication, scheduledAt: scheduledAt).copyWith(
      status: MedicationStatus.taken,
      actionAt: DateTime.now(),
      clearSnooze: true,
    );
    _replaceRecord(record);
    final repository = _repository;
    if (repository is FirestoreMedicationRepository) {
      final remaining = await repository.saveTakenRecordAndUpdateStock(
        _elderlyId,
        record,
      );
      if (remaining != null) {
        final index = _schedules.indexWhere((item) => item.id == medication.id);
        if (index != -1) {
          _schedules[index] = _schedules[index].copyWithStockRemaining(
            remaining,
          );
        }
      }
      notifyListeners();
    } else {
      await _saveAndNotify(record);
    }
  }

  Future<void> snooze(
    MedicationSchedule medication,
    Duration duration, {
    DateTime? scheduledAt,
  }) async {
    final record = recordFor(medication, scheduledAt: scheduledAt).copyWith(
      status: MedicationStatus.snoozed,
      actionAt: DateTime.now(),
      snoozedUntil: DateTime.now().add(duration),
    );
    _replaceRecord(record);
    await _saveAndNotify(record);
  }

  Future<void> markMissed(
    MedicationSchedule medication, {
    DateTime? scheduledAt,
  }) async {
    final record = recordFor(medication, scheduledAt: scheduledAt).copyWith(
      status: MedicationStatus.missed,
      actionAt: DateTime.now(),
      clearSnooze: true,
    );
    _replaceRecord(record);
    await _saveAndNotify(record);
  }

  List<MedicationRecord> recordsBetween(DateTime start, DateTime end) {
    return _records
        .where(
          (record) =>
              !record.scheduledAt.isBefore(start) &&
              record.scheduledAt.isBefore(end),
        )
        .toList()
      ..sort(
        (first, second) => second.scheduledAt.compareTo(first.scheduledAt),
      );
  }

  MedicationSchedule scheduleFor(String medicationId, {DateTime? scheduledAt}) {
    if (scheduledAt != null) {
      for (final record in _records) {
        if (record.medicationId == medicationId &&
            record.scheduledAt.year == scheduledAt.year &&
            record.scheduledAt.month == scheduledAt.month &&
            record.scheduledAt.day == scheduledAt.day &&
            record.scheduledAt.hour == scheduledAt.hour &&
            record.scheduledAt.minute == scheduledAt.minute &&
            record.scheduleSnapshot != null) {
          return record.scheduleSnapshot!;
        }
      }
    }
    final index = _schedules.indexWhere(
      (medication) => medication.id == medicationId,
    );
    if (index != -1) return _schedules[index];

    final previousTime = scheduledAt ?? DateTime.now();
    return MedicationSchedule(
      id: medicationId,
      name: 'Archived medication',
      dose: 'Previous schedule',
      instruction: 'No longer active',
      category: 'Archived',
      hour: previousTime.hour,
      minute: previousTime.minute,
      visual: 'tablet',
      instructionSource: 'Not specified',
    );
  }

  void _replaceRecord(MedicationRecord replacement) {
    final index = _records.indexWhere(
      (record) => record.key == replacement.key,
    );
    if (index == -1) {
      _records.add(replacement);
    } else {
      _records[index] = replacement;
    }
  }

  Future<void> _ensureRecordsForDate(
    DateTime date, {
    required bool persist,
  }) async {
    final targetDate = dateOnly(date);
    for (final medication in _schedules) {
      if (!medication.isScheduledOn(targetDate)) continue;
      for (final occurrence in occurrencesForDate(medication, targetDate)) {
        final key = recordKeyFor(medication, occurrence);
        final existingIndex = _records.indexWhere(
          (record) => record.key == key,
        );
        if (existingIndex != -1) {
          final existing = _records[existingIndex];
          final aligned = _alignSingleDailyOccurrence(
            existing,
            medication,
            occurrence,
          );
          if (!identical(aligned, existing)) {
            _records[existingIndex] = aligned;
            if (persist) {
              await _repository?.saveRecord(_elderlyId, aligned);
            }
          }
          continue;
        }
        final record = MedicationRecord(
          medicationId: medication.id,
          scheduledAt: occurrence,
          status: MedicationStatus.pending,
          scheduleSnapshot: medication,
        );
        _records.add(record);
        if (persist) await _repository?.saveRecord(_elderlyId, record);
      }
    }
  }

  Future<void> _markPastPendingRecordsMissed() async {
    final today = dateOnly(DateTime.now());
    final replacements = <MedicationRecord>[];
    for (final record in _records) {
      if (!dateOnly(record.scheduledAt).isBefore(today)) continue;
      if (record.status != MedicationStatus.pending &&
          record.status != MedicationStatus.snoozed) {
        continue;
      }
      replacements.add(
        record.copyWith(
          status: MedicationStatus.missed,
          clearActionAt: true,
          clearSnooze: true,
        ),
      );
    }
    for (final replacement in replacements) {
      _replaceRecord(replacement);
      await _repository?.saveRecord(_elderlyId, replacement);
    }
  }

  Future<void> _saveAndNotify(MedicationRecord record) async {
    await _repository?.saveRecord(_elderlyId, record);
    notifyListeners();
  }

  Future<List<MedicationRecord>> _loadLegacyRecords() async {
    final preferences = await SharedPreferences.getInstance();
    final stored = preferences.getString(_legacyStorageKey);
    if (stored == null) return <MedicationRecord>[];
    try {
      final decoded = jsonDecode(stored) as List<dynamic>;
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(MedicationRecord.fromJson)
          .toList();
    } catch (_) {
      return <MedicationRecord>[];
    }
  }

  static List<MedicationRecord> _createPreviewRecords(
    DateTime now,
    List<MedicationSchedule> schedules,
  ) {
    final today = dateOnly(now);
    final yesterday = today.subtract(const Duration(days: 1));
    final records = <MedicationRecord>[];
    for (final medication in schedules) {
      if (!medication.isScheduledOn(today)) continue;
      for (final occurrence in scheduledOccurrences(medication, today)) {
        records.add(
          MedicationRecord(
            medicationId: medication.id,
            scheduledAt: occurrence,
            status: medication.id == 'vitamin_d'
                ? MedicationStatus.taken
                : MedicationStatus.pending,
            actionAt: medication.id == 'vitamin_d'
                ? occurrence.add(const Duration(minutes: 2))
                : null,
            scheduleSnapshot: medication,
          ),
        );
      }
    }
    for (final medication in schedules.take(2)) {
      if (!medication.isScheduledOn(yesterday)) continue;
      for (final occurrence in scheduledOccurrences(medication, yesterday)) {
        records.add(
          MedicationRecord(
            medicationId: medication.id,
            scheduledAt: occurrence,
            status: MedicationStatus.taken,
            actionAt: occurrence.add(const Duration(minutes: 3)),
            scheduleSnapshot: medication,
          ),
        );
      }
    }
    return records;
  }

  static DateTime dateOnly(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  static MedicationRecord _alignSingleDailyOccurrence(
    MedicationRecord record,
    MedicationSchedule medication,
    DateTime occurrence,
  ) {
    final sameOccurrence =
        record.scheduledAt.year == occurrence.year &&
        record.scheduledAt.month == occurrence.month &&
        record.scheduledAt.day == occurrence.day &&
        record.scheduledAt.hour == occurrence.hour &&
        record.scheduledAt.minute == occurrence.minute;
    final snoozePredatesOccurrence =
        record.status == MedicationStatus.snoozed &&
        record.snoozedUntil != null &&
        record.snoozedUntil!.isBefore(occurrence);
    if (medication.timesPerDay != 1 ||
        (sameOccurrence && !snoozePredatesOccurrence)) {
      return record;
    }
    return MedicationRecord(
      medicationId: record.medicationId,
      scheduledAt: occurrence,
      status: record.status == MedicationStatus.taken
          ? MedicationStatus.taken
          : MedicationStatus.pending,
      actionAt: record.status == MedicationStatus.taken
          ? record.actionAt
          : null,
      snoozedUntil: null,
      scheduleSnapshot: medication,
    );
  }

  static DateTime scheduledDateTime(
    MedicationSchedule medication,
    DateTime date,
  ) => DateTime(
    date.year,
    date.month,
    date.day,
    medication.hour,
    medication.minute,
  );

  static List<DateTime> scheduledOccurrences(
    MedicationSchedule medication,
    DateTime date,
  ) => medication.dailyReminderMinutes
      .map(
        (minutes) => DateTime(
          date.year,
          date.month,
          date.day,
          minutes ~/ 60,
          minutes % 60,
        ),
      )
      .toList(growable: false);

  static String recordKeyFor(
    MedicationSchedule medication,
    DateTime scheduledAt,
  ) => recordKey(
    medication.id,
    scheduledAt,
    includeTime: medication.timesPerDay > 1,
  );

  static String recordKey(
    String medicationId,
    DateTime date, {
    bool includeTime = false,
  }) {
    final day =
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    if (!includeTime) return '${day}_$medicationId';
    final time =
        '${date.hour.toString().padLeft(2, '0')}'
        '${date.minute.toString().padLeft(2, '0')}';
    return '${day}_${time}_$medicationId';
  }
}
