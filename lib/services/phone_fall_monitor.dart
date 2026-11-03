import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'activity_recognition_service.dart';

/// The phone UI observes the Android service; leaving a screen never stops it.
ActivityMonitor phoneActivityMonitor() =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android
    ? PhoneFallMonitor.instance
    : ActivityRecognitionService.phone();

class PhoneFallMonitor extends ChangeNotifier implements ActivityMonitor {
  PhoneFallMonitor();
  static final instance = PhoneFallMonitor();
  static const methods = MethodChannel('com.shca.shca/phone_monitoring');
  static const events = EventChannel('com.shca.shca/phone_monitoring_events');
  static const alarmPermissions = MethodChannel(
    'com.shca.shca/alarm_permissions',
  );

  StreamSubscription<dynamic>? _subscription;
  bool enabled = false;
  String? pendingFallId;
  DateTime? fallDeadline;
  String? deliveryEventId, deliveryMessage, deliveryTitle;
  ActivitySnapshot _snapshot = const ActivitySnapshot(
    label: 'Fall detection off',
    state: ActivityMonitorState.stopped,
    message: 'Turn on fall detection to monitor in the background.',
  );

  @override
  ActivitySnapshot get snapshot => _snapshot;

  void _apply(Map<dynamic, dynamic> value) {
    enabled = value['enabled'] == true;
    deliveryEventId = value['deliveryEventId'] as String?;
    deliveryMessage = value['deliveryMessage'] as String?;
    deliveryTitle = value['deliveryTitle'] as String?;
    pendingFallId = value['pendingFallId'] as String?;
    final deadline = value['fallDeadline'] as num?;
    fallDeadline = deadline == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(deadline.toInt());
    final measuredAt = value['updatedAt'] as num?;
    _snapshot = ActivitySnapshot(
      label: value['label'] as String? ?? 'Preparing sensors',
      confidence: (value['confidence'] as num?)?.toDouble() ?? 0,
      fallProbability: (value['fallProbability'] as num?)?.toDouble() ?? 0,
      updatedAt: measuredAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(measuredAt.toInt()),
      state: ActivityMonitorState.values.firstWhere(
        (state) => state.name == value['state'],
        orElse: () => enabled
            ? ActivityMonitorState.starting
            : ActivityMonitorState.stopped,
      ),
      possibleFall: value['possibleFall'] == true,
      message: value['message'] as String? ?? '',
    );
    notifyListeners();
  }

  @override
  Future<void> start() async {
    _subscription ??= events.receiveBroadcastStream().listen((dynamic value) {
      if (value is Map) _apply(value);
    }, onError: (Object error) => debugPrint('Phone monitoring: $error'));
    try {
      final value = await methods.invokeMapMethod('attach');
      if (value != null) _apply(value);
    } on MissingPluginException {
      // Non-Android previews have no native service.
    } on PlatformException catch (error) {
      _apply({
        'enabled': false,
        'state': 'unavailable',
        'label': 'Monitoring unavailable',
        'message':
            error.message ?? 'Could not start background fall detection.',
      });
    }
  }

  Future<void> _ensureAlarmDisplayAccess() async {
    final access = await methods.invokeMapMethod('getAlarmDisplayAccess') ?? {};
    if (access['appearOnTop'] != true) {
      final granted = await alarmPermissions.invokeMethod<bool>(
        'requestAppearOnTopPermission',
      );
      if (granted != true) {
        throw PlatformException(
          code: 'overlay-required',
          message:
              'Allow SHCA to appear on top so fall alarms can open over other apps.',
        );
      }
    }
    if (access['fullScreen'] != true) {
      final granted = await alarmPermissions.invokeMethod<bool>(
        'requestFullScreenPermission',
      );
      if (granted != true) {
        throw PlatformException(
          code: 'full-screen-required',
          message:
              'Allow full-screen alarms for SHCA so a fall warning can wake the lock screen.',
        );
      }
    }
  }

  Future<void> setEnabled(bool value) async {
    if (value) await _ensureAlarmDisplayAccess();
    final state = await methods.invokeMapMethod('setEnabled', {
      'enabled': value,
    });
    if (state != null) _apply(state);
  }

  Future<void> respondToFall({required String eventId, required bool send}) =>
      methods.invokeMethod<void>('respondToFall', {
        'eventId': eventId,
        'send': send,
      });

  @override
  Future<void> stop() => setEnabled(false);

  @override
  void acknowledgePossibleFall() {
    final id = pendingFallId;
    if (id != null) unawaited(respondToFall(eventId: id, send: false));
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
