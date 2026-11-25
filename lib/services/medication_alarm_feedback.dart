import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps a ringing medication alert independent of its notification lifecycle.
class MedicationAlarmFeedback {
  static const _channel = MethodChannel('com.shca.shca/alarm_permissions');

  // Start the native medicine alarm feedback for this alert.
  static Future<void> start(String alarmKey) =>
      _invoke('startMedicationAlarmFeedback', alarmKey);

  // Stop feedback for this alert without silencing a newer alarm.
  static Future<void> stop([String? alarmKey]) =>
      _invoke('stopMedicationAlarmFeedback', alarmKey);

  // Send the feedback request to Android and handle unavailable native support.
  static Future<void> _invoke(String method, String? alarmKey) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>(method, <String, Object?>{
        'alarmKey': alarmKey,
      });
    } on MissingPluginException {
      // Non-Android embedders do not provide the alarm feedback channel.
    } on PlatformException catch (error) {
      debugPrint('Medication alarm feedback failed: $error');
    }
  }
}
