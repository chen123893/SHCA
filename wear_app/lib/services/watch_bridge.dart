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
  factory WatchMedication.fromMap(Map<dynamic, dynamic>? map) {
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
  bool get isAvailable => id.isNotEmpty && occurrenceId.isNotEmpty;
  bool isToday(DateTime now) =>
      scheduledAt?.year == now.year &&
      scheduledAt?.month == now.month &&
      scheduledAt?.day == now.day;
}

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
  Stream<Map<String, dynamic>> get events => _controller.stream;
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

  Future<void> setMonitoringEnabled(bool enabled) =>
      _methods.invokeMethod<void>('setMonitoringEnabled', {'enabled': enabled});

  Future<WatchInitialState> refresh() async => WatchInitialState.fromMap(
    await _methods
        .invokeMapMethod<dynamic, dynamic>('getInitialState')
        .timeout(const Duration(seconds: 8)),
  );
  Future<Map<String, dynamic>> signIn({
    required String email,
    required String password,
  }) async => Map<String, dynamic>.from(
    await _methods
            .invokeMapMethod('signIn', {'email': email, 'password': password})
            .timeout(const Duration(seconds: 35)) ??
        {},
  );
  Future<Map<String, dynamic>> startPhoneSignIn({bool renew = false}) async =>
      Map<String, dynamic>.from(
        await _methods.invokeMapMethod('startPhoneSignIn', {'renew': renew}) ??
            {},
      );
  Future<void> cancelPhoneSignIn() =>
      _methods.invokeMethod<void>('cancelPhoneSignIn');
  Future<String?> editCredential({
    required String field,
    required String value,
  }) => _methods.invokeMethod<String>('editCredential', {
    'field': field,
    'value': value,
  });
  Future<void> signOut() => _methods.invokeMethod<void>('signOut');
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

  Future<bool> confirmPossibleFall(double probability) async =>
      await _methods.invokeMethod<bool>('confirmPossibleFall', {
        'probability': probability,
      }) ??
      false;
  Future<void> requestFallScreenPermission() =>
      _methods.invokeMethod<void>('requestFallScreenPermission');

  Future<void> startFallVibration() =>
      _methods.invokeMethod<void>('startFallVibration');
  Future<void> stopVibration() => _methods.invokeMethod<void>('stopVibration');
  Future<void> testVibration() => _methods.invokeMethod<void>('testVibration');
  Future<void> requestAlarmPermission() =>
      _methods.invokeMethod<void>('requestAlarmPermission');
  Future<void> requestNotifications() =>
      _methods.invokeMethod<void>('requestNotifications');
  Future<void> dispose() async {
    await _subscription?.cancel();
    await _controller.close();
  }
}
