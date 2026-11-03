import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'medication_service.dart';

/// Sync is scoped to the signed-in elderly account and survives page navigation.
class WatchScheduleSync {
  WatchScheduleSync._();
  static final instance = WatchScheduleSync._();
  static const _methods = MethodChannel('com.shca.shca/wearable');
  StreamSubscription<User?>? _auth;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _profile;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _schedules;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _records;
  Timer? _timer;
  int _generation = 0;
  String _uid = '';
  String _role = '';
  String _signature = '';
  bool _schedulesLoaded = false, _recordsLoaded = false;
  List<MedicationSchedule> _items = [];
  List<MedicationRecord> _doses = [];

  void start() {
    if (!Platform.isAndroid || _auth != null) return;
    _auth = FirebaseAuth.instance.authStateChanges().listen(_onUser);
    _timer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_publish()),
    );
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _generation++;
    await _auth?.cancel();
    await _profile?.cancel();
    await _schedules?.cancel();
    await _records?.cancel();
    _auth = null;
  }

  Future<void> _onUser(User? user) async {
    final generation = ++_generation;
    await _profile?.cancel();
    await _schedules?.cancel();
    await _records?.cancel();
    if (generation != _generation) return;
    _uid = user?.uid ?? '';
    _role = '';
    _signature = '';
    _items = [];
    _doses = [];
    _schedulesLoaded = false;
    _recordsLoaded = false;
    await _publish(forceClear: true);
    if (user == null || generation != _generation) return;
    _profile = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .snapshots()
        .listen((doc) async {
          if (generation != _generation) return;
          final role = doc.data()?['role'] as String? ?? '';
          if (_role == role && _schedules != null) return;
          _role = role;
          await _schedules?.cancel();
          _schedules = null;
          await _records?.cancel();
          _records = null;
          if (generation != _generation) return;
          _items = [];
          _doses = [];
          _schedulesLoaded = false;
          _recordsLoaded = false;
          await _publish(forceClear: true);
          if (role != 'elderly' || generation != _generation) return;
          final db = FirebaseFirestore.instance;
          _schedules = db
              .collection('medications')
              .where('elderlyId', isEqualTo: _uid)
              .snapshots()
              .listen(
                (snapshot) {
                  if (generation != _generation) return;
                  _items = snapshot.docs
                      .where(
                        (d) =>
                            d.data()['active'] != false &&
                            !isLegacyDemoMedicationData(d.data()),
                      )
                      .map((d) => MedicationSchedule.fromFirestore(d.data()))
                      .toList();
                  _schedulesLoaded = true;
                  unawaited(_publish());
                },
                onError: (Object error) =>
                    debugPrint('Watch medicine sync unavailable: $error'),
              );
          _records = db
              .collection('medication_records')
              .where('elderlyId', isEqualTo: _uid)
              .snapshots()
              .listen(
                (snapshot) {
                  if (generation != _generation) return;
                  _doses = deduplicateMedicationRecords(
                    snapshot.docs.map(
                      (d) => MedicationRecord.fromFirestore(d.data()),
                    ),
                  );
                  _recordsLoaded = true;
                  unawaited(_publish());
                },
                onError: (Object error) =>
                    debugPrint('Watch dose records unavailable: $error'),
              );
        });
  }

  Future<void> _publish({bool forceClear = false}) async {
    final uid = _uid, role = _role;
    try {
      await _methods.invokeMethod<void>('setPhoneState', {
        'userId': uid,
        'role': role,
      });
      if (!forceClear &&
          role == 'elderly' &&
          (!_schedulesLoaded || !_recordsLoaded)) {
        return;
      }
      final now = DateTime.now();
      final rows = !forceClear && role == 'elderly'
          ? todayWatchDoses(_items, _doses, now)
          : <Map<String, dynamic>>[];
      final json = jsonEncode(rows);
      final signature = '$uid:$role:${now.year}-${now.month}-${now.day}:$json';
      if (!forceClear && signature == _signature) return;
      await _methods.invokeMethod<void>('syncMedication', {
        'userId': role == 'elderly' ? uid : '',
        'scheduleJson': json,
      });
      if (_uid == uid && _role == role) _signature = signature;
    } catch (error) {
      debugPrint('Watch sync will retry: $error');
    }
  }
}

/// Keep the original occurrence ID/time when snoozing; only remindAt changes.
@visibleForTesting
List<Map<String, dynamic>> todayWatchDoses(
  List<MedicationSchedule> schedules,
  List<MedicationRecord> records,
  DateTime now,
) {
  final rows = <Map<String, dynamic>>[];
  for (final medicine in schedules) {
    if (!medicine.hasAutomaticReminder || !medicine.isScheduledOn(now)) {
      continue;
    }
    for (final scheduled in MedicationController.scheduledOccurrences(
      medicine,
      now,
    )) {
      final key = MedicationController.recordKeyFor(medicine, scheduled);
      MedicationRecord? record;
      for (final value in records) {
        if (value.key == key) {
          record = value;
          break;
        }
      }
      if (record?.status == MedicationStatus.taken ||
          record?.status == MedicationStatus.missed) {
        continue;
      }
      final remindAt = record?.snoozedUntil ?? scheduled;
      // Include today's due doses as well as upcoming ones; the watch marks
      // overdue entries and never re-rings an already delivered occurrence.
      rows.add({
        'id': medicine.id,
        'occurrenceId': key,
        'name': medicine.name,
        'dose': medicine.doseSummary,
        'instruction': medicine.instruction,
        'scheduledAt': scheduled.millisecondsSinceEpoch,
        'remindAt': remindAt.millisecondsSinceEpoch,
        'status': record?.status.name ?? 'pending',
      });
    }
  }
  rows.sort((a, b) => (a['remindAt'] as int).compareTo(b['remindAt'] as int));
  return rows;
}
