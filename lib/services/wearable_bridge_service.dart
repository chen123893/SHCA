import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class WearableStatus {
  const WearableStatus({
    this.connected = false,
    this.label = '',
    this.confidence = 0,
    this.fallProbability = 0,
    this.possibleFall = false,
    this.updatedAt,
  });

  factory WearableStatus.fromMap(Map<dynamic, dynamic> map) {
    final timestamp = (map['updatedAt'] as num?)?.toInt() ?? 0;
    return WearableStatus(
      connected: map['connected'] == true,
      label: (map['label'] as String?) ?? '',
      confidence: (map['confidence'] as num?)?.toDouble() ?? 0,
      fallProbability: (map['fallProbability'] as num?)?.toDouble() ?? 0,
      possibleFall: map['possibleFall'] == true,
      updatedAt: timestamp <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(timestamp),
    );
  }

  final bool connected;
  final String label;
  final double confidence;
  final double fallProbability;
  final bool possibleFall;
  final DateTime? updatedAt;

  /// A linked watch is not necessarily running the SHCA watch app. A recent
  /// status proves that its own sensor/model pipeline is currently producing
  /// results; connection alone only proves that Wear OS can reach the phone.
  bool get monitoringActive {
    final timestamp = updatedAt;
    return connected &&
        label.isNotEmpty &&
        label != 'Fall detection off' &&
        timestamp != null &&
        DateTime.now().difference(timestamp).abs() <
            const Duration(seconds: 20);
  }
}

/// Flutter-facing bridge to the native Wear OS Data Layer implementation.
class WearableBridgeService {
  WearableBridgeService._();

  static final WearableBridgeService instance = WearableBridgeService._();
  static const MethodChannel _methods = MethodChannel('com.shca.shca/wearable');
  static const EventChannel _events = EventChannel(
    'com.shca.shca/wearable_events',
  );

  final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<dynamic>? _nativeSubscription;

  Stream<Map<String, dynamic>> get events => _controller.stream;

  Future<void> initialize() async {
    if (!Platform.isAndroid || _nativeSubscription != null) return;
    _nativeSubscription = _events.receiveBroadcastStream().listen(
      (dynamic value) {
        if (value is Map) {
          _controller.add(Map<String, dynamic>.from(value));
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('Wear OS bridge event error: $error');
      },
    );
  }

  Future<WearableStatus> getStatus() async {
    if (!Platform.isAndroid) return const WearableStatus();
    try {
      final result = await _methods.invokeMapMethod<dynamic, dynamic>(
        'getStatus',
      );
      return WearableStatus.fromMap(result ?? const <dynamic, dynamic>{});
    } on PlatformException catch (error) {
      debugPrint('Could not read Wear OS status: ${error.message}');
      return const WearableStatus();
    }
  }

  Future<List<Map<String, dynamic>>> takePendingEvents() async {
    if (!Platform.isAndroid) return const <Map<String, dynamic>>[];
    try {
      final values = await _methods.invokeListMethod<dynamic>(
        'getPendingEvents',
      );
      return (values ?? const <dynamic>[])
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList(growable: false);
    } on PlatformException catch (error) {
      debugPrint('Could not read pending watch events: ${error.message}');
      return const <Map<String, dynamic>>[];
    }
  }

  Future<void> clearPendingEvents() async {
    if (!Platform.isAndroid) return;
    try {
      await _methods.invokeMethod<void>('clearPendingEvents');
    } on PlatformException catch (error) {
      debugPrint('Could not clear processed watch events: ${error.message}');
    }
  }

  Future<void> syncMedication({
    required String id,
    required String name,
    required String dose,
    required String instruction,
    required DateTime scheduledAt,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _methods.invokeMethod<void>('syncMedication', <String, dynamic>{
        'id': id,
        'name': name,
        'dose': dose,
        'instruction': instruction,
        'scheduledAt': scheduledAt.millisecondsSinceEpoch,
      });
    } on PlatformException catch (error) {
      debugPrint(
        'Could not sync the next medicine to the watch: ${error.message}',
      );
    }
  }

  Future<void> acknowledgeFall() async {
    if (!Platform.isAndroid) return;
    try {
      await _methods.invokeMethod<void>('acknowledgeFall');
    } on PlatformException catch (error) {
      debugPrint(
        'Could not acknowledge the watch fall prompt: ${error.message}',
      );
    }
  }
}
