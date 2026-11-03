import 'package:firebase_auth/firebase_auth.dart';
import 'package:shca/services/push_notification_service.dart';
import 'package:shca/services/phone_fall_monitor.dart';

typedef SessionTask = Future<void> Function();

class AppSessionService {
  AppSessionService({
    SessionTask? signOut,
    SessionTask? clearMedicationAlarms,
    SessionTask? unregisterCaregiver,
    SessionTask? stopFallDetection,
    this.cleanupTimeout = const Duration(seconds: 2),
  }) : _stopFallDetection = stopFallDetection ?? PhoneFallMonitor.instance.stop,
       _signOut = signOut ?? FirebaseAuth.instance.signOut,
       _clearMedicationAlarms =
           clearMedicationAlarms ??
           PushNotificationService.instance.clearMedicationAlarmsForSignOut,
       _unregisterCaregiver =
           unregisterCaregiver ??
           PushNotificationService.instance.unregisterCaregiver;

  final SessionTask _stopFallDetection;
  final SessionTask _signOut;
  final SessionTask _clearMedicationAlarms;
  final SessionTask _unregisterCaregiver;
  final Duration cleanupTimeout;

  Future<void> signOut({required bool caregiver}) async {
    await Future.wait<void>([
      _bestEffort(_clearMedicationAlarms),
      if (!caregiver) _bestEffort(_stopFallDetection),
      if (caregiver) _bestEffort(_unregisterCaregiver),
    ]);
    await _signOut();
  }

  Future<void> _bestEffort(SessionTask task) async {
    try {
      await task().timeout(cleanupTimeout);
    } catch (_) {
      // Local notification cleanup must never keep the user signed in.
    }
  }
}
