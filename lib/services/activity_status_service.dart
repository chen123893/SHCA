import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shca/services/activity_recognition_service.dart';
import 'package:shca/services/wearable_bridge_service.dart';

/// Publishes only small activity summaries for linked caregivers.
/// Raw accelerometer and gyroscope samples never leave the device.
class ActivityStatusService {
  ActivityStatusService._();

  static final ActivityStatusService instance = ActivityStatusService._();
  static const Duration _heartbeat = Duration(seconds: 30);

  final Map<String, DateTime> _lastSent = <String, DateTime>{};
  final Map<String, String> _lastSignature = <String, String>{};

  Future<void> publishPhone(ActivitySnapshot snapshot) => _publish(
    source: 'phone',
    label: snapshot.label,
    confidence: snapshot.confidence,
    fallProbability: snapshot.fallProbability,
    possibleFall: snapshot.possibleFall,
    active: snapshot.state == ActivityMonitorState.active,
    measuredAt: snapshot.updatedAt,
  );

  Future<void> publishWatch(WearableStatus status) => _publish(
    source: 'watch',
    label: status.label,
    confidence: status.confidence,
    fallProbability: status.fallProbability,
    possibleFall: status.possibleFall,
    active: status.monitoringActive,
    measuredAt: status.updatedAt,
  );

  Future<void> _publish({
    required String source,
    required String label,
    required double confidence,
    required double fallProbability,
    required bool possibleFall,
    required bool active,
    required DateTime? measuredAt,
  }) async {
    if (Firebase.apps.isEmpty) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || !user.emailVerified) return;
    final now = DateTime.now();
    final signature = '$label:$active:$possibleFall';
    final lastSent = _lastSent[source];
    if (_lastSignature[source] == signature &&
        lastSent != null &&
        now.difference(lastSent) < _heartbeat) {
      return;
    }
    _lastSignature[source] = signature;
    _lastSent[source] = now;
    try {
      await FirebaseFirestore.instance
          .collection('activity_status')
          .doc(user.uid)
          .set(<String, dynamic>{
            'elderlyId': user.uid,
            source: <String, dynamic>{
              'label': label,
              'confidence': confidence.clamp(0, 1),
              'fallProbability': fallProbability.clamp(0, 1),
              'possibleFall': possibleFall,
              'active': active,
              'measuredAt': measuredAt == null
                  ? FieldValue.serverTimestamp()
                  : Timestamp.fromDate(measuredAt),
              'publishedAt': FieldValue.serverTimestamp(),
            },
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
    } catch (_) {
      // Monitoring remains available locally if cloud status is unavailable.
    }
  }
}
