import 'package:flutter/services.dart';

class AlertVibrationService {
  AlertVibrationService._();

  static const MethodChannel _channel = MethodChannel('com.shca.shca/wearable');

  static Future<void> startFall({
    Duration duration = const Duration(seconds: 30),
  }) async {
    try {
      await _channel.invokeMethod<void>('startFallAlert', <String, Object>{
        'durationMillis': duration.inMilliseconds,
      });
    } on MissingPluginException {
      await HapticFeedback.heavyImpact();
    } on PlatformException {
      await HapticFeedback.heavyImpact();
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stopFallAlert');
    } on MissingPluginException {
      // Native sound and vibration are only available on supported Android devices.
    } on PlatformException {
      // An audio or vibration failure must never block the emergency dialog.
    }
  }
}
