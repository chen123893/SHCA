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
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

class MedicationNotificationTarget {
  const MedicationNotificationTarget({
    required this.elderlyId,
    required this.medicationId,
    this.scheduledAt,
    this.reminderAt,
    this.medicationSnapshot,
  });

  final String elderlyId;
  final String medicationId;
  final DateTime? scheduledAt;
  final DateTime? reminderAt;
  final MedicationSchedule? medicationSnapshot;

  bool belongsTo(String? userId) => userId != null && elderlyId == userId;

  String toPayload() => jsonEncode(<String, Object>{
    'type': 'medication_reminder',
    'elderlyId': elderlyId,
    'medicationId': medicationId,
    if (scheduledAt != null) 'scheduledAt': scheduledAt!.millisecondsSinceEpoch,
    if (reminderAt != null) 'reminderAt': reminderAt!.millisecondsSinceEpoch,
    if (medicationSnapshot != null)
      'medicationSnapshot': medicationSnapshot!.toRecordSnapshot(),
  });

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
  ({bool notifications, bool exact, bool fullScreen, bool appearOnTop})?
  _lastMedicationAlarmPermissions;

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
  String _allAlarmIdsKey(String elderlyId) =>
      'medication_all_alarm_ids_v1_$elderlyId';
  String _scheduledAlarmIdsKey(String elderlyId) =>
      'medication_alarm_ids_$elderlyId';

  Stream<String> get notificationTapPayloads =>
      _notificationTapController.stream;

  Future<void> initialize() async {
    if (_initialized) return;

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

  void _deliverMedicationPayload(String payload) {
    _pendingNotificationPayload = payload;
    _notificationTapController.add(payload);
  }

  Future<void> _reconcileMedicationAlarmOwner(String? signedInUserId) async {
    final preferences = await SharedPreferences.getInstance();
    final owner = preferences.getString(_activeAlarmOwnerKey);
    if (signedInUserId == null ||
        (owner != null && owner.isNotEmpty && owner != signedInUserId)) {
      await _cancelMedicationRemindersInternal();
    }
  }

  /// Stops every medication alarm owned by this installation. Emergency
  /// notifications are not touched.
  Future<void> clearMedicationAlarmsForSignOut() async {
    await MedicationAlarmFeedback.stop();
    await initialize();
    await _cancelMedicationRemindersInternal();
  }

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

  String? takePendingNotificationPayload() {
    final payload = _pendingNotificationPayload;
    _pendingNotificationPayload = null;
    return payload;
  }

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

  Future<void> syncMedicationReminders({
    required String elderlyId,
    required List<MedicationSchedule> schedules,
  }) async {
    if (!Platform.isAndroid) return;
    await initialize();
    if (FirebaseAuth.instance.currentUser?.uid != elderlyId) {
      await _cancelMedicationRemindersInternal(elderlyId: elderlyId);
      return;
    }
    final preferences = await SharedPreferences.getInstance();
    final owner = preferences.getString(_activeAlarmOwnerKey);
    if (owner != null && owner.isNotEmpty && owner != elderlyId) {
      await _cancelMedicationRemindersInternal();
    }
    final storageKey = _scheduledAlarmIdsKey(elderlyId);
    final previousIds = preferences.getStringList(storageKey) ?? const [];
    for (final storedId in previousIds) {
      final id = int.tryParse(storedId);
      if (id != null) {
        _medicationForegroundTimers.remove(id)?.cancel();
        await _notifications.cancel(id: id);
        await _cancelNativeMedicationAlarm(id);
      }
    }

    final scheduleMode = await _medicationScheduleMode();
    final ids = <String>[];
    for (final medication in schedules.where(
      (item) => item.hasAutomaticReminder,
    )) {
      final occurrences = _nextMedicationOccurrences(medication);
      for (final scheduledDate in occurrences) {
        final payload = _medicationPayload(
          elderlyId,
          medication,
          scheduledDate,
        );
        final occurrenceKey = scheduledDate.millisecondsSinceEpoch.toString();
        final id = medicationNotificationId(
          elderlyId,
          '${medication.id}_$occurrenceKey',
        );
        ids.add(id.toString());
        await _rememberMedicationAlarm(elderlyId, id);
        await _notifications.zonedSchedule(
          id: id,
          title: 'Time to take medicine',
          body:
              '${medication.name} • ${medication.doseSummary} • ${medication.instruction}',
          scheduledDate: scheduledDate,
          notificationDetails: _medicationNotificationDetails(),
          androidScheduleMode: scheduleMode,
          payload: payload,
        );
        await _scheduleNativeMedicationAlarm(
          id: id,
          scheduledDate: scheduledDate,
          payload: payload,
        );
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
    await preferences.setStringList(storageKey, ids);
    final allIds =
        preferences.getStringList(_allAlarmIdsKey(elderlyId))?.toSet() ??
        <String>{};
    allIds.removeAll(previousIds);
    allIds.addAll(ids);
    await preferences.setStringList(
      _allAlarmIdsKey(elderlyId),
      allIds.toList()..sort(),
    );
  }

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

  Future<void> snoozeMedicationReminder({
    required String elderlyId,
    required MedicationSchedule medication,
    required DateTime scheduledAt,
    Duration duration = const Duration(minutes: 10),
  }) async {
    if (!Platform.isAndroid) return;
    await initialize();
    if (FirebaseAuth.instance.currentUser?.uid != elderlyId) return;
    final id = medicationNotificationId(
      elderlyId,
      '${medication.id}_${scheduledAt.millisecondsSinceEpoch}_snooze',
    );
    final scheduledDate = tz.TZDateTime.now(tz.local).add(duration);
    final payload = _medicationPayload(
      elderlyId,
      medication,
      scheduledAt,
      reminderAt: scheduledDate,
    );
    await _notifications.zonedSchedule(
      id: id,
      title: 'Medication reminder',
      body:
          '${medication.name} • ${medication.doseSummary} • ${medication.instruction}',
      scheduledDate: scheduledDate,
      notificationDetails: _medicationNotificationDetails(),
      androidScheduleMode: await _medicationScheduleMode(),
      payload: payload,
    );
    await _scheduleNativeMedicationAlarm(
      id: id,
      scheduledDate: scheduledDate,
      payload: payload,
    );
    await _rememberMedicationAlarm(elderlyId, id);
    _scheduleForegroundMedicationScreen(
      id: id,
      payload: payload,
      hour: medication.hour,
      minute: medication.minute,
      scheduledDate: scheduledDate,
      repeatDaily: false,
    );
  }

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

  Future<void> _scheduleNativeMedicationAlarm({
    required int id,
    required DateTime scheduledDate,
    required String payload,
  }) async {
    if (!Platform.isAndroid) return;
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
    } on PlatformException catch (error) {
      debugPrint('Native full-screen alarm $id was not scheduled: $error');
    }
  }

  Future<void> _cancelNativeMedicationAlarm(int id) async {
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

  List<tz.TZDateTime> _nextMedicationOccurrences(
    MedicationSchedule medication, {
    int limit = 64,
  }) {
    final now = tz.TZDateTime.now(tz.local);
    final today = DateTime(now.year, now.month, now.day);
    final start = medication.startDate == null
        ? today
        : MedicationController.dateOnly(medication.startDate!);
    var date = start.isAfter(today) ? start : today;
    final end = medication.endDate == null
        ? null
        : MedicationController.dateOnly(medication.endDate!);
    final occurrences = <tz.TZDateTime>[];

    // Schedule a rolling set of future alarms. The set is refreshed whenever
    // the elderly opens the app or the caregiver changes a schedule.
    for (
      var checked = 0;
      checked < 3660 && occurrences.length < limit;
      checked++
    ) {
      if (end != null && date.isAfter(end)) break;
      if (medication.isScheduledOn(date)) {
        for (final minutes in medication.dailyReminderMinutes) {
          final occurrence = tz.TZDateTime(
            tz.local,
            date.year,
            date.month,
            date.day,
            minutes ~/ 60,
            minutes % 60,
          );
          if (occurrence.isAfter(now)) occurrences.add(occurrence);
          if (occurrences.length >= limit) break;
        }
      }
      date = date.add(const Duration(days: 1));
    }
    return occurrences;
  }

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
  ).toPayload();

  @visibleForTesting
  static int medicationNotificationId(String elderlyId, String medicationId) {
    final bytes = sha256.convert('$elderlyId:$medicationId'.codeUnits).bytes;
    return ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) &
        0x7fffffff;
  }

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

  String _tokenDocumentId(String token) =>
      sha256.convert(token.codeUnits).toString();
}
