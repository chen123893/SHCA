import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

@immutable
class WatchMedication {
  const WatchMedication({
    this.id = '',
    this.occurrenceId = '',
    this.name = 'Medicine',
    this.dose = '',
    this.instruction = '',
    this.scheduledAt,
    this.remindAt,
    this.status = 'pending',
  });
  // Read the dose details received from the native watch layer.
  factory WatchMedication.fromMap(Map<dynamic, dynamic>? map) {
    // Convert a saved millisecond timestamp into a watch reminder time.
    DateTime? time(String key) {
      final value = (map?[key] as num?)?.toInt() ?? 0;
      return value > 0 ? DateTime.fromMillisecondsSinceEpoch(value) : null;
    }

    return WatchMedication(
      id: map?['id'] as String? ?? '',
      occurrenceId: map?['occurrenceId'] as String? ?? '',
      name: map?['name'] as String? ?? 'Medicine',
      dose: map?['dose'] as String? ?? '',
      instruction: map?['instruction'] as String? ?? '',
      scheduledAt: time('scheduledAt'),
      remindAt: time('remindAt') ?? time('scheduledAt'),
      status: map?['status'] as String? ?? 'pending',
    );
  }
  final String id, occurrenceId, name, dose, instruction, status;
  final DateTime? scheduledAt, remindAt;
  // Check that the medicine has both a schedule ID and a dose ID.
  bool get isAvailable => id.isNotEmpty && occurrenceId.isNotEmpty;
  // Keep only doses scheduled for the watch's current day.
  bool isToday(DateTime now) =>
      scheduledAt?.year == now.year &&
      scheduledAt?.month == now.month &&
      scheduledAt?.day == now.day;
}

// Get today's unfinished future reminders in time order.
List<WatchMedication> upcomingToday(
  Iterable<WatchMedication> values,
  DateTime now,
) =>
    values
        .where(
          (m) =>
              m.isToday(now) &&
              m.status != 'taken' &&
              m.remindAt != null &&
              m.remindAt!.isAfter(now),
        )
        .toList()
      ..sort((a, b) => a.remindAt!.compareTo(b.remindAt!));

@immutable
class WatchInitialState {
  const WatchInitialState({
    this.connected = false,
    this.phoneReady = false,
    this.exactAlarms = false,
    this.notificationsAllowed = false,
    this.signedIn = false,
    this.cloudReady = false,
    this.fallScreenAllowed = false,
    this.monitoringEnabled = true,
    this.accountName = '',
    this.medications = const [],
    this.medication = const WatchMedication(),
    this.launchEvent,
    this.emergencyAck,
  });
  // Read the watch account, permission and medicine state from Android.
  factory WatchInitialState.fromMap(Map<dynamic, dynamic>? map) =>
      WatchInitialState(
        connected: map?['connected'] == true,
        phoneReady: map?['phoneReady'] == true,
        exactAlarms: map?['exactAlarms'] == true,
        notificationsAllowed: map?['notificationsAllowed'] == true,
        signedIn: map?['signedIn'] == true,
        cloudReady: map?['cloudReady'] == true,
        fallScreenAllowed: map?['fallScreenAllowed'] == true,
        monitoringEnabled: map?['monitoringEnabled'] != false,
        accountName: map?['accountName'] as String? ?? '',
        medications: ((map?['medications'] as List?) ?? [])
            .whereType<Map>()
            .map(WatchMedication.fromMap)
            .toList(),
        medication: WatchMedication.fromMap(map?['medication'] as Map?),
        launchEvent: map?['launchEvent'] is Map
            ? Map<String, dynamic>.from(map!['launchEvent'] as Map)
            : null,
        emergencyAck: map?['emergencyAck'] is Map
            ? Map<String, dynamic>.from(map!['emergencyAck'] as Map)
            : null,
      );
  final bool connected, phoneReady, exactAlarms, notificationsAllowed;
  final bool signedIn, cloudReady, fallScreenAllowed, monitoringEnabled;
  final String accountName;
  final List<WatchMedication> medications;
  final WatchMedication medication;
  final Map<String, dynamic>? launchEvent, emergencyAck;
}

class WatchBridge {
  static const _methods = MethodChannel('com.shca.shca/watch_bridge');
  static const _events = EventChannel('com.shca.shca/watch_events');
  StreamSubscription<dynamic>? _subscription;
  final _controller = StreamController<Map<String, dynamic>>.broadcast();
  // Expose watch events through one shared stream.
  Stream<Map<String, dynamic>> get events => _controller.stream;
  // Subscribe to native events once, then read the current watch state.
  Future<WatchInitialState> initialize() async {
    _subscription ??= _events.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is Map) _controller.add(Map<String, dynamic>.from(event));
      },
      onError: (Object error) =>
          debugPrint('Watch connection unavailable: $error'),
    );
    return refresh();
  }

  // Save the watch's fall-monitoring switch through Android.
  Future<void> setMonitoringEnabled(bool enabled) =>
      _methods.invokeMethod<void>('setMonitoringEnabled', {'enabled': enabled});

  // Read the latest watch state with a timeout if Android does not answer.
  Future<WatchInitialState> refresh() async => WatchInitialState.fromMap(
    await _methods
        .invokeMapMethod<dynamic, dynamic>('getInitialState')
        .timeout(const Duration(seconds: 8)),
  );
  // Send the entered watch credentials to the native sign-in flow.
  Future<Map<String, dynamic>> signIn({
    required String email,
    required String password,
  }) async => Map<String, dynamic>.from(
    await _methods
            .invokeMapMethod('signIn', {'email': email, 'password': password})
            .timeout(const Duration(seconds: 35)) ??
        {},
  );
  // Start or renew a request to sign in using the paired phone.
  Future<Map<String, dynamic>> startPhoneSignIn({bool renew = false}) async =>
      Map<String, dynamic>.from(
        await _methods.invokeMapMethod('startPhoneSignIn', {'renew': renew}) ??
            {},
      );
  // Cancel the current phone-assisted sign-in request.
  Future<void> cancelPhoneSignIn() =>
      _methods.invokeMethod<void>('cancelPhoneSignIn');
  // Open the native watch editor for an email or password field.
  Future<String?> editCredential({
    required String field,
    required String value,
  }) => _methods.invokeMethod<String>('editCredential', {
    'field': field,
    'value': value,
  });
  // Ask Android to clear the watch's current session.
  Future<void> signOut() => _methods.invokeMethod<void>('signOut');
  // Send the latest watch activity result to the native bridge.
  Future<bool> publishStatus({
    required String label,
    required double confidence,
    required double fallProbability,
    required bool possibleFall,
    required DateTime updatedAt,
  }) async {
    try {
      return await _methods.invokeMethod<bool>('publishStatus', {
            'label': label,
            'confidence': confidence,
            'fallProbability': fallProbability,
            'possibleFall': possibleFall,
            'updatedAt': updatedAt.millisecondsSinceEpoch,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  // Pass the emergency event to the watch's native delivery flow.
  Future<Map<String, dynamic>> sendEmergency({
    required String eventId,
    required DateTime createdAt,
    required String source,
    required double fallProbability,
  }) async => Map<String, dynamic>.from(
    await _methods
            .invokeMapMethod('sendEmergency', {
              'eventId': eventId,
              'createdAt': createdAt.millisecondsSinceEpoch,
              'source': source,
              'fallProbability': fallProbability,
            })
            .timeout(const Duration(seconds: 10)) ??
        {},
  );
  // Send the dose response using its original occurrence ID.
  Future<void> medicationAction({
    required WatchMedication medication,
    required String action,
    required String eventId,
  }) async {
    await _methods
        .invokeMapMethod('sendMedicationAction', {
          'eventId': eventId,
          'createdAt': DateTime.now().millisecondsSinceEpoch,
          'occurrenceId': medication.occurrenceId,
          'action': action,
        })
        .timeout(const Duration(seconds: 10));
  }

  // Ask the native fall countdown to confirm the detected event.
  Future<bool> confirmPossibleFall(double probability) async =>
      await _methods.invokeMethod<bool>('confirmPossibleFall', {
        'probability': probability,
      }) ??
      false;
  // Open the setting needed to display a fall warning over other screens.
  Future<void> requestFallScreenPermission() =>
      _methods.invokeMethod<void>('requestFallScreenPermission');

  // Start the watch's fall warning vibration.
  Future<void> startFallVibration() =>
      _methods.invokeMethod<void>('startFallVibration');
  // Stop the watch's current warning vibration.
  Future<void> stopVibration() => _methods.invokeMethod<void>('stopVibration');
  // Run a short vibration test on the watch.
  Future<void> testVibration() => _methods.invokeMethod<void>('testVibration');
  // Open the watch setting for exact medicine alarms.
  Future<void> requestAlarmPermission() =>
      _methods.invokeMethod<void>('requestAlarmPermission');
  // Ask for permission to show watch notifications.
  Future<void> requestNotifications() =>
      _methods.invokeMethod<void>('requestNotifications');
  // Cancel the native event subscription and close the shared event stream.
  Future<void> dispose() async {
    await _subscription?.cancel();
    await _controller.close();
  }
}
