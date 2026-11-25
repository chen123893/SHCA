import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shca/services/medication_service.dart';
import 'package:shca/services/medication_alarm_feedback.dart';
import 'medication_reminder_plan.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

class MedicationNotificationTarget {
  const MedicationNotificationTarget({
    required this.elderlyId,
    required this.medicationId,
    this.scheduledAt,
    this.reminderAt,
    this.medicationSnapshot,
    this.occurrenceId,
  });

  final String elderlyId;
  final String medicationId;
  final String? occurrenceId;
  final DateTime? scheduledAt;
  final DateTime? reminderAt;
  final MedicationSchedule? medicationSnapshot;

  // Ignore a medicine notification that belongs to another signed-in account.
  bool belongsTo(String? userId) => userId != null && elderlyId == userId;

  // Encode the medicine and dose details carried by the notification.
  String toPayload() => jsonEncode(<String, Object>{
    'type': 'medication_reminder',
    'elderlyId': elderlyId,
    'medicationId': medicationId,
    'occurrenceId': ?occurrenceId,
    if (scheduledAt != null) 'scheduledAt': scheduledAt!.millisecondsSinceEpoch,
    if (reminderAt != null) 'reminderAt': reminderAt!.millisecondsSinceEpoch,
    if (medicationSnapshot != null)
      'medicationSnapshot': medicationSnapshot!.toRecordSnapshot(),
  });

  // Read a medicine notification only when its required fields are valid.
  static MedicationNotificationTarget? fromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final value = jsonDecode(payload);
      if (value is! Map<String, dynamic> ||
          value['type'] != 'medication_reminder') {
        return null;
      }
      final elderlyId = value['elderlyId'] as String?;
      final medicationId = value['medicationId'] as String?;
      final scheduledAtMillis = value['scheduledAt'] as num?;
      final reminderAtMillis = value['reminderAt'] as num?;
      if (elderlyId == null ||
          elderlyId.isEmpty ||
          medicationId == null ||
          medicationId.isEmpty) {
        return null;
      }
      MedicationSchedule? snapshot;
      final snapshotData = value['medicationSnapshot'];
      if (snapshotData is Map<String, dynamic> && scheduledAtMillis != null) {
        try {
          snapshot = MedicationSchedule.fromRecordSnapshot(
            medicationId: medicationId,
            scheduledAt: DateTime.fromMillisecondsSinceEpoch(
              scheduledAtMillis.toInt(),
            ),
            data: snapshotData,
          );
        } catch (_) {
          // An unusable snapshot must not prevent an older alarm from opening.
        }
      }
      return MedicationNotificationTarget(
        medicationSnapshot: snapshot,
        occurrenceId: value['occurrenceId'] as String?,
        elderlyId: elderlyId,
        medicationId: medicationId,
        scheduledAt: scheduledAtMillis == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(scheduledAtMillis.toInt()),
        reminderAt: reminderAtMillis == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(reminderAtMillis.toInt()),
      );
    } catch (_) {
      return null;
    }
  }
}

class PushNotificationService {
  PushNotificationService._();

  static final PushNotificationService instance = PushNotificationService._();
  static const MethodChannel _alarmPermissionChannel = MethodChannel(
    'com.shca.shca/alarm_permissions',
  );
  static const EventChannel _alarmEventChannel = EventChannel(
    'com.shca.shca/alarm_events',
  );

  static final AndroidNotificationChannel emergencyChannel =
      AndroidNotificationChannel(
        'shca_emergency_alerts_v2',
        'Emergency alerts',
        description: 'Urgent fall and SOS alerts from a linked elderly user.',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
        vibrationPattern: Int64List.fromList(<int>[0, 700, 250, 700, 850]),
        audioAttributesUsage: AudioAttributesUsage.alarm,
      );

  static final AndroidNotificationChannel medicationChannel =
      AndroidNotificationChannel(
        'shca_medication_alarms_v2',
        'Medication alarms',
        description: 'Alarms for scheduled medicine reminders.',
        importance: Importance.max,
        playSound: true,
        sound: UriAndroidNotificationSound(
          'content://settings/system/alarm_alert',
        ),
        enableVibration: true,
        vibrationPattern: Int64List.fromList(<int>[0, 600, 350, 600, 350, 600]),
        audioAttributesUsage: AudioAttributesUsage.alarm,
      );

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  StreamSubscription<String>? _tokenSubscription;
  StreamSubscription<User?>? _authSubscription;
  StreamSubscription<dynamic>? _nativeAlarmSubscription;
  bool _initialized = false;
  Future<void>? _initializing;
  Future<void> _alarmWork = Future<void>.value();
  final Map<String, MedicationRecord> _localDoseResponses = {};
  final Map<String, Map<int, String>> _scheduledMedicationSpecs = {};

  // Run alarm updates one at a time so rescheduling cannot overlap.
  Future<void> _queueAlarmWork(Future<void> Function() action) {
    final next = _alarmWork.then((_) => action());
    _alarmWork = next.catchError((Object error) {
      debugPrint('Medication alarm update failed: $error');
    });
    return next;
  }

  ({bool notifications, bool exact, bool fullScreen, bool appearOnTop})?
  _lastMedicationAlarmPermissions;

  // Read the most recently checked Android alarm permissions.
  ({bool notifications, bool exact, bool fullScreen, bool appearOnTop})?
  get lastMedicationAlarmPermissions => _lastMedicationAlarmPermissions;

  String? _caregiverId;
  String? _registeredToken;
  String? _pendingNotificationPayload;
  final Map<int, Timer> _medicationForegroundTimers = <int, Timer>{};
  final StreamController<String> _notificationTapController =
      StreamController<String>.broadcast();
  static const String _alarmOwnersKey = 'medication_alarm_owners_v1';
  static const String _activeAlarmOwnerKey = 'active_medication_alarm_owner_v1';
  // Keep each account's remembered alarm IDs under its own preference key.
  String _allAlarmIdsKey(String elderlyId) =>
      'medication_all_alarm_ids_v1_$elderlyId';
  // Keep each account's current schedule IDs under its own preference key.
  String _scheduledAlarmIdsKey(String elderlyId) =>
      'medication_alarm_ids_$elderlyId';

  // Let the app open an alert when a notification is tapped.
  Stream<String> get notificationTapPayloads =>
      _notificationTapController.stream;

  // Share one initialisation request if several screens need notifications at once.
  Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    return _initializing ??= _initialize().whenComplete(() {
      _initializing = null;
    });
  }

  // Set up notification channels, tap handlers and account cleanup.
  Future<void> _initialize() async {
    tz_data.initializeTimeZones();
    var timezoneIdentifier = '';
    try {
      final localTimezone = await FlutterTimezone.getLocalTimezone();
      timezoneIdentifier = localTimezone.identifier;
    } catch (error) {
      debugPrint('Could not read the device timezone: $error');
    }
    _setLocalTimezone(timezoneIdentifier);

    await _notifications.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload == null || payload.isEmpty) return;
        _deliverMedicationPayload(payload);
      },
    );
    final android = _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(emergencyChannel);
    await android?.createNotificationChannel(medicationChannel);

    if (Platform.isAndroid) {
      _nativeAlarmSubscription ??= _alarmEventChannel
          .receiveBroadcastStream()
          .listen(
            (event) {
              if (event is String && event.isNotEmpty) {
                _deliverMedicationPayload(event);
              }
            },
            onError: (Object error) =>
                debugPrint('Native medication alarm event failed: $error'),
          );
      try {
        final pending = await _alarmPermissionChannel.invokeMethod<String>(
          'takePendingMedicationAlarm',
        );
        if (pending != null && pending.isNotEmpty) {
          _deliverMedicationPayload(pending);
        }
      } on PlatformException catch (error) {
        debugPrint('Could not read the pending native alarm: $error');
      }
    }

    final launchDetails = await _notifications
        .getNotificationAppLaunchDetails();
    final launchPayload = launchDetails?.notificationResponse?.payload;
    if (launchDetails?.didNotificationLaunchApp == true &&
        launchPayload != null &&
        launchPayload.isNotEmpty) {
      _pendingNotificationPayload = launchPayload;
    }

    FirebaseMessaging.onMessage.listen(_showForegroundNotification);
    _initialized = true;
    await _reconcileMedicationAlarmOwner(
      FirebaseAuth.instance.currentUser?.uid,
    );
    _authSubscription ??= FirebaseAuth.instance.authStateChanges().listen(
      (user) => unawaited(_reconcileMedicationAlarmOwner(user?.uid)),
      onError: (Object error) =>
          debugPrint('Medication alarm account check failed: $error'),
    );
  }

  // Keep the medicine alert payload and notify the app to open it.
  void _deliverMedicationPayload(String payload) {
    _pendingNotificationPayload = payload;
    _notificationTapController.add(payload);
  }

  // Clear old medicine alarms when the signed-in account changes.
  Future<void> _reconcileMedicationAlarmOwner(String? signedInUserId) async {
    final preferences = await SharedPreferences.getInstance();
    final owner = preferences.getString(_activeAlarmOwnerKey);
    if (signedInUserId == null ||
        (owner != null && owner.isNotEmpty && owner != signedInUserId)) {
      await _queueAlarmWork(() => _cancelMedicationRemindersInternal());
    }
  }

  /// Stops every medication alarm owned by this installation. Emergency
  /// notifications are not touched.
  Future<void> clearMedicationAlarmsForSignOut() async {
    await MedicationAlarmFeedback.stop();
    await initialize();
    await _queueAlarmWork(() => _cancelMedicationRemindersInternal());
  }

  // Cancel the remembered medicine alarms for the requested account.
  Future<void> _cancelMedicationRemindersInternal({String? elderlyId}) async {
    final preferences = await SharedPreferences.getInstance();
    final owners =
        preferences.getStringList(_alarmOwnersKey)?.toSet() ?? <String>{};
    final activeOwner = preferences.getString(_activeAlarmOwnerKey);
    if (activeOwner != null && activeOwner.isNotEmpty) owners.add(activeOwner);
    final targets = elderlyId == null
        ? owners.toList(growable: false)
        : <String>[elderlyId];
    final cancelledIds = <int>{};
    for (final owner in targets) {
      _scheduledMedicationSpecs.remove(owner);
      final values = <String>{
        ...?preferences.getStringList(_scheduledAlarmIdsKey(owner)),
        ...?preferences.getStringList(_allAlarmIdsKey(owner)),
      };
      for (final value in values) {
        final id = int.tryParse(value);
        if (id == null || !cancelledIds.add(id)) continue;
        _medicationForegroundTimers.remove(id)?.cancel();
        await _notifications.cancel(id: id);
        await _cancelNativeMedicationAlarm(id);
      }
      if (Platform.isAndroid) {
        await _alarmPermissionChannel.invokeMethod<void>(
          'cancelMedicationAlarmsForOwner',
          {'elderlyId': owner},
        );
      }
      await preferences.remove(_scheduledAlarmIdsKey(owner));
      await preferences.remove(_allAlarmIdsKey(owner));
      owners.remove(owner);
    }
    if (elderlyId == null) {
      for (final timer in _medicationForegroundTimers.values) {
        timer.cancel();
      }
      _medicationForegroundTimers.clear();
      _pendingNotificationPayload = null;
      await preferences.remove(_activeAlarmOwnerKey);
    } else if (activeOwner == elderlyId) {
      await preferences.remove(_activeAlarmOwnerKey);
    }
    await preferences.setStringList(_alarmOwnersKey, owners.toList()..sort());
  }

  // Remember this alarm ID so it can be cancelled later.
  Future<void> _rememberMedicationAlarm(String elderlyId, int id) async {
    final preferences = await SharedPreferences.getInstance();
    final owners =
        preferences.getStringList(_alarmOwnersKey)?.toSet() ?? <String>{};
    owners.add(elderlyId);
    final ids =
        preferences.getStringList(_allAlarmIdsKey(elderlyId))?.toSet() ??
        <String>{};
    ids.add(id.toString());
    await preferences.setStringList(_alarmOwnersKey, owners.toList()..sort());
    await preferences.setStringList(
      _allAlarmIdsKey(elderlyId),
      ids.toList()..sort(),
    );
    await preferences.setString(_activeAlarmOwnerKey, elderlyId);
  }

  // Remove the cancelled alarm ID from local tracking.
  Future<void> _forgetMedicationAlarm(String elderlyId, int id) async {
    final preferences = await SharedPreferences.getInstance();
    final ids =
        preferences.getStringList(_allAlarmIdsKey(elderlyId))?.toSet() ??
        <String>{};
    ids.remove(id.toString());
    await preferences.setStringList(
      _allAlarmIdsKey(elderlyId),
      ids.toList()..sort(),
    );
  }

  // Use the phone's timezone when scheduling medicine alarms.
  void _setLocalTimezone(String deviceIdentifier) {
    // Some Android devices return legacy IANA aliases which are intentionally
    // omitted from the compact timezone database bundled by the Dart package.
    const aliases = <String, String>{
      'Asia/Kuala_Lumpur': 'Asia/Singapore',
      'Malaysia/West': 'Asia/Singapore',
    };
    final candidates = <String>{
      if (deviceIdentifier.trim().isNotEmpty) deviceIdentifier.trim(),
      ?aliases[deviceIdentifier.trim()],
      'Asia/Singapore',
      'UTC',
    };
    for (final identifier in candidates) {
      try {
        tz.setLocalLocation(tz.getLocation(identifier));
        if (identifier != deviceIdentifier && deviceIdentifier.isNotEmpty) {
          debugPrint(
            'Using timezone $identifier for device timezone $deviceIdentifier.',
          );
        }
        return;
      } catch (_) {
        // Try the next compatible location below.
      }
    }
    tz.setLocalLocation(tz.UTC);
    debugPrint('Falling back to UTC for medication reminder scheduling.');
  }

  // Read the waiting notification payload once, then clear it.
  String? takePendingNotificationPayload() {
    final payload = _pendingNotificationPayload;
    _pendingNotificationPayload = null;
    return payload;
  }

  // Check the Android permissions needed for medicine alarms.
  Future<({bool notifications, bool exact, bool fullScreen, bool appearOnTop})>
  medicationAlarmPermissionStatus() async {
    await initialize();
    if (!Platform.isAndroid) {
      return _lastMedicationAlarmPermissions = (
        notifications: true,
        exact: true,
        fullScreen: true,
        appearOnTop: true,
      );
    }
    final android = _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    Map<dynamic, dynamic>? nativeStatus;
    try {
      nativeStatus = await _alarmPermissionChannel
          .invokeMapMethod<dynamic, dynamic>('getStatus');
    } on MissingPluginException {
      // Unit tests and non-Android embedders do not install the native channel.
    } on PlatformException catch (error) {
      debugPrint('Could not read native alarm permission status: $error');
    }
    final preferences = await SharedPreferences.getInstance();
    return _lastMedicationAlarmPermissions = (
      notifications:
          nativeStatus?['notifications'] as bool? ??
          await android?.areNotificationsEnabled() ??
          true,
      exact:
          nativeStatus?['exact'] as bool? ??
          await android?.canScheduleExactNotifications() ??
          true,
      appearOnTop: nativeStatus?['appearOnTop'] as bool? ?? false,
      fullScreen:
          nativeStatus?['fullScreen'] as bool? ??
          preferences.getBool('medication_full_screen_permission') ??
          false,
    );
  }

  // Open the system permission prompts needed for reliable medicine alarms.
  Future<({bool notifications, bool exact, bool fullScreen, bool appearOnTop})>
  requestMedicationAlarmPermissions() async {
    await initialize();
    if (!Platform.isAndroid) {
      return (
        notifications: true,
        exact: true,
        fullScreen: true,
        appearOnTop: true,
      );
    }
    final android = _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.requestNotificationsPermission();
    if (await android?.canScheduleExactNotifications() == false) {
      await android?.requestExactAlarmsPermission();
    }
    final fullScreen =
        await android?.requestFullScreenIntentPermission() ?? false;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('medication_full_screen_permission', fullScreen);
    await _alarmPermissionChannel.invokeMethod<bool>(
      'requestAppearOnTopPermission',
    );
    return medicationAlarmPermissionStatus();
  }

  // Update future alarms from the schedules and saved dose responses.
  Future<void> syncMedicationReminders({
    required String elderlyId,
    required List<MedicationSchedule> schedules,
    List<MedicationRecord>? records,
  }) async {
    if (!Platform.isAndroid) return;
    await initialize();
    await _queueAlarmWork(() async {
      if (FirebaseAuth.instance.currentUser?.uid != elderlyId) {
        await _cancelMedicationRemindersInternal(elderlyId: elderlyId);
        return;
      }
      final saved =
          records ??
          await FirestoreMedicationRepository().loadRecords(elderlyId);
      if (FirebaseAuth.instance.currentUser?.uid != elderlyId) return;
      final scheduleById = {for (final item in schedules) item.id: item};
      final merged = deduplicateMedicationRecords([
        ...saved,
        ..._localDoseResponses.entries
            .where((e) => e.key.startsWith('$elderlyId:'))
            .map((e) => e.value),
      ]);
      for (final record in merged) {
        final medication = scheduleById[record.medicationId];
        final aligned = medication == null || medication.timesPerDay != 1
            ? record
            : MedicationController.alignRecordToOccurrence(
                record,
                medication,
                MedicationController.scheduledDateTime(
                  medication,
                  record.scheduledAt,
                ),
              );
        await _updateNativeMedicationRecord(elderlyId, aligned);
      }
      final plan = medicationReminderPlan(
        schedules: schedules,
        records: merged,
        now: DateTime.now(),
      );
      final desiredIds = {
        for (final occurrence in plan)
          medicationNotificationId(elderlyId, occurrence.alarmKey).toString(),
      };
      final preferences = await SharedPreferences.getInstance();
      final owner = preferences.getString(_activeAlarmOwnerKey);
      if (owner != null && owner != elderlyId) {
        await _cancelMedicationRemindersInternal();
      }
      final previousIds = {
        ...?preferences.getStringList(_scheduledAlarmIdsKey(elderlyId)),
        ...?preferences.getStringList(_allAlarmIdsKey(elderlyId)),
      };
      for (final removedId in previousIds.difference(desiredIds)) {
        final id = int.tryParse(removedId);
        if (id == null) continue;
        _medicationForegroundTimers.remove(id)?.cancel();
        await _notifications.cancel(id: id);
        await _cancelNativeMedicationAlarm(id);
        await _forgetMedicationAlarm(elderlyId, id);
      }
      for (final occurrence in plan) {
        await _scheduleMedicationOccurrence(elderlyId, occurrence);
      }
      await preferences.setStringList(
        _scheduledAlarmIdsKey(elderlyId),
        desiredIds.toList(),
      );
    });
  }

  /// Apply a saved response immediately, before another screen or Firestore
  /// listener has a chance to rebuild the rolling alarm schedule.
  Future<void> applyMedicationRecord(
    String elderlyId,
    MedicationRecord record,
  ) async {
    if (!Platform.isAndroid ||
        FirebaseAuth.instance.currentUser?.uid != elderlyId) {
      return;
    }
    await initialize();
    _localDoseResponses['$elderlyId:${record.key}'] = record;
    for (final suffix in ['', '_snooze']) {
      final id = medicationNotificationId(
        elderlyId,
        '${record.medicationId}_${record.scheduledAt.millisecondsSinceEpoch}$suffix',
      );
      _medicationForegroundTimers.remove(id)?.cancel();
    }
    // Persist cancellation before waiting behind any rolling schedule rebuild.
    await _updateNativeMedicationRecord(elderlyId, record);
    for (final suffix in ['', '_snooze']) {
      final id = medicationNotificationId(
        elderlyId,
        '${record.medicationId}_${record.scheduledAt.millisecondsSinceEpoch}$suffix',
      );
      // Also stop the plugin fallback when native exact alarms were unavailable.
      await _notifications.cancel(id: id);
    }
    final pending = MedicationNotificationTarget.fromPayload(
      _pendingNotificationPayload,
    );
    if (pending?.elderlyId == elderlyId &&
        pending?.medicationId == record.medicationId &&
        pending?.scheduledAt == record.scheduledAt) {
      _pendingNotificationPayload = null;
    }
    // The saved response and native guard are durable now. Cleanup can wait
    // behind a resync without holding the alert screen's confirmation.
    unawaited(
      _queueAlarmWork(() async {
        if (FirebaseAuth.instance.currentUser?.uid != elderlyId) return;
        for (final suffix in ['', '_snooze']) {
          final id = medicationNotificationId(
            elderlyId,
            '${record.medicationId}_${record.scheduledAt.millisecondsSinceEpoch}$suffix',
          );
          _medicationForegroundTimers.remove(id)?.cancel();
          await _notifications.cancel(id: id);
          await _cancelNativeMedicationAlarm(id);
          await _forgetMedicationAlarm(elderlyId, id);
        }
        if (record.status == MedicationStatus.snoozed &&
            record.snoozedUntil?.isAfter(DateTime.now()) == true &&
            record.scheduleSnapshot != null) {
          await _scheduleMedicationOccurrence(
            elderlyId,
            MedicationReminderOccurrence(
              record.scheduleSnapshot!,
              record.scheduledAt,
              record.snoozedUntil!,
              snoozed: true,
            ),
          );
        }
      }),
    );
  }

  // Save the dose response on Android before other alarm work can run.
  Future<void> _updateNativeMedicationRecord(
    String elderlyId,
    MedicationRecord record,
  ) async {
    await _alarmPermissionChannel.invokeMethod<void>('updateMedicationRecord', {
      'elderlyId': elderlyId,
      'medicationId': record.medicationId,
      'occurrenceId': record.key,
      'scheduledAt': record.scheduledAt.millisecondsSinceEpoch,
      'status': record.status.name,
      'actionAt': record.actionAt?.millisecondsSinceEpoch ?? 0,
      'remindAt': record.snoozedUntil?.millisecondsSinceEpoch ?? 0,
    });
  }

  // Schedule this dose only if its alarm details have changed.
  Future<void> _scheduleMedicationOccurrence(
    String elderlyId,
    MedicationReminderOccurrence occurrence,
  ) async {
    if (FirebaseAuth.instance.currentUser?.uid != elderlyId) return;
    final medication = occurrence.medication;
    final id = medicationNotificationId(elderlyId, occurrence.alarmKey);
    final scheduledDate = tz.TZDateTime.from(occurrence.remindAt, tz.local);
    if (!scheduledDate.isAfter(tz.TZDateTime.now(tz.local))) return;
    final payload = _medicationPayload(
      elderlyId,
      medication,
      occurrence.scheduledAt,
      reminderAt: occurrence.snoozed ? occurrence.remindAt : null,
    );
    final specification = '${scheduledDate.millisecondsSinceEpoch}:$payload';
    final installed = _scheduledMedicationSpecs.putIfAbsent(
      elderlyId,
      () => {},
    );
    if (installed[id] == specification) return;
    await _rememberMedicationAlarm(elderlyId, id);
    final preferences = await SharedPreferences.getInstance();
    final ids =
        preferences.getStringList(_scheduledAlarmIdsKey(elderlyId))?.toSet() ??
        <String>{};
    ids.add(id.toString());
    await preferences.setStringList(
      _scheduledAlarmIdsKey(elderlyId),
      ids.toList(),
    );
    final nativeScheduled = await _scheduleNativeMedicationAlarm(
      id: id,
      scheduledDate: scheduledDate,
      payload: payload,
    );
    if (nativeScheduled) {
      installed[id] = specification;
    } else {
      await _notifications.zonedSchedule(
        id: id,
        title: 'Time to take medicine',
        body:
            '${medication.name} • ${medication.doseSummary} • ${medication.instruction}',
        scheduledDate: scheduledDate,
        notificationDetails: _medicationNotificationDetails(),
        androidScheduleMode: await _medicationScheduleMode(),
        payload: payload,
      );
    }
    if (!nativeScheduled) {
      _scheduleForegroundMedicationScreen(
        id: id,
        payload: payload,
        hour: medication.hour,
        minute: medication.minute,
        scheduledDate: scheduledDate,
        repeatDaily: false,
      );
    }
  }

  // Use an in-app timer when the native alarm could not be scheduled.
  void _scheduleForegroundMedicationScreen({
    required int id,
    required String payload,
    required int hour,
    required int minute,
    required tz.TZDateTime scheduledDate,
    bool repeatDaily = true,
  }) {
    _medicationForegroundTimers.remove(id)?.cancel();
    final delay = scheduledDate.difference(tz.TZDateTime.now(tz.local));
    _medicationForegroundTimers[id] = Timer(
      delay.isNegative ? Duration.zero : delay,
      () {
        _medicationForegroundTimers.remove(id);
        final target = MedicationNotificationTarget.fromPayload(payload);
        if (target == null ||
            !target.belongsTo(FirebaseAuth.instance.currentUser?.uid)) {
          unawaited(_notifications.cancel(id: id));
          return;
        }
        _pendingNotificationPayload = payload;
        _notificationTapController.add(payload);
        if (repeatDaily) {
          _scheduleForegroundMedicationScreen(
            id: id,
            payload: payload,
            hour: hour,
            minute: minute,
            scheduledDate: _nextMedicationTime(hour, minute),
          );
        }
      },
    );
  }

  // Apply the snoozed record through the same alarm update path.
  Future<void> snoozeMedicationReminder({
    required String elderlyId,
    required MedicationSchedule medication,
    required DateTime scheduledAt,
    Duration duration = const Duration(minutes: 10),
  }) => applyMedicationRecord(
    elderlyId,
    MedicationRecord(
      medicationId: medication.id,
      scheduledAt: scheduledAt,
      status: MedicationStatus.snoozed,
      actionAt: DateTime.now(),
      snoozedUntil: DateTime.now().add(duration),
      scheduleSnapshot: medication,
    ),
  );

  // Schedule a short test so the user can check the alarm setup.
  Future<void> showMedicationTestAlarm({
    required String elderlyId,
    required MedicationSchedule medication,
  }) async {
    await initialize();
    if (FirebaseAuth.instance.currentUser?.uid != elderlyId) return;
    final id = medicationNotificationId(elderlyId, '${medication.id}_test');
    await _rememberMedicationAlarm(elderlyId, id);
    await _notifications.show(
      id: id,
      title: 'Test medication alarm',
      body:
          '${medication.name} • ${medication.doseSummary} • ${medication.instruction}',
      notificationDetails: _medicationNotificationDetails(
        fullScreen: false,
        insistent: true,
      ),
    );
  }

  // Remove the pending test alarm and its foreground timer.
  Future<void> cancelMedicationTestAlarm({
    required String elderlyId,
    required MedicationSchedule medication,
  }) async {
    await initialize();
    final id = medicationNotificationId(elderlyId, '${medication.id}_test');
    await _notifications.cancel(id: id);
    await _cancelNativeMedicationAlarm(id);
    await _forgetMedicationAlarm(
      elderlyId,
      medicationNotificationId(elderlyId, '${medication.id}_test'),
    );
  }

  // Use exact alarms when allowed and fall back when permission is missing.
  Future<AndroidScheduleMode> _medicationScheduleMode() async {
    final android = _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final exact = await android?.canScheduleExactNotifications();
    return exact == false
        ? AndroidScheduleMode.inexactAllowWhileIdle
        : AndroidScheduleMode.exactAllowWhileIdle;
  }

  // Ask Android to schedule a medicine alarm that can work outside Flutter.
  Future<bool> _scheduleNativeMedicationAlarm({
    required int id,
    required DateTime scheduledDate,
    required String payload,
  }) async {
    if (!Platform.isAndroid) return false;
    try {
      final scheduled = await _alarmPermissionChannel
          .invokeMethod<bool>('scheduleMedicationAlarm', <String, Object>{
            'id': id,
            'triggerAtMillis': scheduledDate.millisecondsSinceEpoch,
            'payload': payload,
          });
      if (scheduled != true) {
        debugPrint('Android could not schedule full-screen alarm $id.');
      }
      return scheduled == true;
    } on PlatformException catch (error) {
      debugPrint('Native full-screen alarm $id was not scheduled: $error');
      return false;
    }
  }

  // Remove the native alarm and its cached schedule details.
  Future<void> _cancelNativeMedicationAlarm(int id) async {
    for (final installed in _scheduledMedicationSpecs.values) {
      installed.remove(id);
    }
    if (!Platform.isAndroid) return;
    try {
      await _alarmPermissionChannel.invokeMethod<void>(
        'cancelMedicationAlarm',
        <String, Object>{'id': id},
      );
    } on PlatformException catch (error) {
      debugPrint('Native full-screen alarm $id was not cancelled: $error');
    }
  }

  // Use the medicine alarm channel with sound, vibration and the alert screen.
  NotificationDetails _medicationNotificationDetails({
    bool fullScreen = true,
    bool insistent = false,
  }) => NotificationDetails(
    android: AndroidNotificationDetails(
      'shca_medication_alarms_v2',
      'Medication alarms',
      channelDescription: 'Alarms for scheduled medicine reminders.',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.alarm,
      visibility: NotificationVisibility.public,
      playSound: true,
      sound: UriAndroidNotificationSound(
        'content://settings/system/alarm_alert',
      ),
      enableVibration: true,
      vibrationPattern: Int64List.fromList(<int>[0, 600, 350, 600, 350, 600]),
      audioAttributesUsage: AudioAttributesUsage.alarm,
      fullScreenIntent: fullScreen,
      ongoing: insistent,
      autoCancel: !insistent,
      additionalFlags: insistent ? Int32List.fromList(<int>[4]) : null,
    ),
  );

  // Find the next occurrence of the requested reminder time.
  tz.TZDateTime _nextMedicationTime(int hour, int minute) {
    final now = tz.TZDateTime.now(tz.local);
    var scheduled = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );
    if (!scheduled.isAfter(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    return scheduled;
  }

  // Attach the account, medicine snapshot and original dose time to the alarm.
  String _medicationPayload(
    String elderlyId,
    MedicationSchedule medication,
    DateTime scheduledAt, {
    DateTime? reminderAt,
  }) => MedicationNotificationTarget(
    elderlyId: elderlyId,
    medicationId: medication.id,
    scheduledAt: scheduledAt,
    reminderAt: reminderAt,
    medicationSnapshot: medication,
    occurrenceId: MedicationController.recordKeyFor(medication, scheduledAt),
  ).toPayload();

  // Make the same notification ID each time for a given account and alarm.
  @visibleForTesting
  static int medicationNotificationId(String elderlyId, String medicationId) {
    final bytes = sha256.convert('$elderlyId:$medicationId'.codeUnits).bytes;
    return ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) &
        0x7fffffff;
  }

  // Register this caregiver phone's push token and follow token changes.
  Future<bool> registerCaregiver(String caregiverId) async {
    try {
      await initialize();
      final settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        debugPrint('FCM registration skipped: notification permission denied.');
        return false;
      }

      final token = await _messaging.getToken();
      if (token == null || token.isEmpty) {
        debugPrint('FCM registration failed: the device returned no token.');
        return false;
      }
      _caregiverId = caregiverId;
      _registeredToken = token;
      await _saveToken(caregiverId, token);

      await _tokenSubscription?.cancel();
      _tokenSubscription = _messaging.onTokenRefresh.listen((newToken) async {
        final activeCaregiverId = _caregiverId;
        if (activeCaregiverId == null) return;
        final oldToken = _registeredToken;
        _registeredToken = newToken;
        if (oldToken != null && oldToken != newToken) {
          await _deleteToken(activeCaregiverId, oldToken);
        }
        await _saveToken(activeCaregiverId, newToken);
      });
      return true;
    } catch (error) {
      debugPrint('FCM caregiver registration failed: $error');
      return false;
    }
  }

  // Remove this phone's caregiver push registration at sign-out.
  Future<void> unregisterCaregiver() async {
    final caregiverId = _caregiverId ?? FirebaseAuth.instance.currentUser?.uid;
    final token = _registeredToken ?? await _messaging.getToken();
    await _tokenSubscription?.cancel();
    _tokenSubscription = null;
    _caregiverId = null;
    _registeredToken = null;
    if (caregiverId != null && token != null) {
      await _deleteToken(caregiverId, token);
    }
    await _messaging.deleteToken();
  }

  // Save the current device token under the caregiver account.
  Future<void> _saveToken(String caregiverId, String token) async {
    await FirebaseFirestore.instance
        .collection('caregiver_profiles')
        .doc(caregiverId)
        .collection('push_tokens')
        .doc(_tokenDocumentId(token))
        .set(<String, dynamic>{
          'userId': caregiverId,
          'token': token,
          'platform': Platform.isAndroid ? 'android' : 'other',
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
  }

  // Delete the saved device token for this installation.
  Future<void> _deleteToken(String caregiverId, String token) async {
    try {
      await FirebaseFirestore.instance
          .collection('caregiver_profiles')
          .doc(caregiverId)
          .collection('push_tokens')
          .doc(_tokenDocumentId(token))
          .delete();
    } on FirebaseException catch (error) {
      debugPrint('Could not remove FCM token: ${error.code}');
    }
  }

  // Show a local notification when a push arrives while the app is open.
  Future<void> _showForegroundNotification(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;
    await _notifications.show(
      id:
          message.messageId?.hashCode ??
          DateTime.now().millisecondsSinceEpoch.remainder(2147483647),
      title: notification.title ?? 'SHCA emergency alert',
      body: notification.body ?? 'A linked elderly user needs assistance.',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'shca_emergency_alerts_v2',
          'Emergency alerts',
          channelDescription:
              'Urgent fall and SOS alerts from a linked elderly user.',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.alarm,
          visibility: NotificationVisibility.public,
          playSound: true,
          enableVibration: true,
          vibrationPattern: Int64List.fromList(<int>[0, 700, 250, 700, 850]),
          audioAttributesUsage: AudioAttributesUsage.alarm,
        ),
      ),
      payload: message.data['alertId'] as String?,
    );
  }

  // Hash the push token to make its Firestore document ID.
  String _tokenDocumentId(String token) =>
      sha256.convert(token.codeUnits).toString();
}
