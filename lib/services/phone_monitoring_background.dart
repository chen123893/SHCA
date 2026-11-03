import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../firebase_options.dart';
import 'activity_recognition_service.dart';
import 'activity_status_service.dart';
import 'care_link_service.dart';
import 'emergency_push_service.dart';
import 'profile_service.dart';

/// Runs in the foreground service's own engine, independently of the UI.
Future<void> runPhoneMonitoring() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await _PhoneMonitoringWorker().start();
}

class _PhoneMonitoringWorker {
  static const _channel = MethodChannel(
    'com.shca.shca/phone_monitoring_worker',
  );
  final _monitor = ActivityRecognitionService.phone();
  String _userId = '';
  Map<String, dynamic>? _pending;
  Timer? _deadline, _retry;
  bool _stopping = false, _delivering = false, _savingFall = false;

  bool get _ownsSession =>
      !_stopping && FirebaseAuth.instance.currentUser?.uid == _userId;

  Future<void> start() async {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'respond':
          final value = Map<String, dynamic>.from(call.arguments as Map);
          await _respond(value['eventId'] as String, value['send'] == true);
          return null;
        case 'shutdown':
          _stopping = true;
          _deadline?.cancel();
          _retry?.cancel();
          _monitor.removeListener(_onMotion);
          await _monitor.stop();
          await ActivityStatusService.instance.publishPhone(_monitor.snapshot);
          return null;
      }
      return null;
    });
    final state = await _channel.invokeMapMethod('ready') ?? {};
    _userId = state['userId'] as String? ?? '';
    if (!_ownsSession || _userId.isEmpty) return;
    if (state['pending'] is Map) {
      _pending = Map<String, dynamic>.from(state['pending'] as Map);
    }
    final action = state['action'];
    if (action is Map) {
      // Apply an already-tapped notification response before restarting its clock.
      unawaited(_respond(action['eventId'] as String, action['send'] == true));
    } else {
      _restorePending();
    }
    _monitor.addListener(_onMotion);
    await _monitor.start();
  }

  void _onMotion() {
    if (!_ownsSession) return;
    final snapshot = _monitor.snapshot;
    unawaited(ActivityStatusService.instance.publishPhone(snapshot));
    if (snapshot.possibleFall && _pending == null && !_savingFall) {
      unawaited(_beginFall(snapshot));
    }
    unawaited(_publish());
  }

  Future<void> _publish() async {
    if (!_ownsSession) return;
    final value = _monitor.snapshot;
    final pending = _pending;
    await _channel.invokeMethod<void>('snapshot', {
      'label': value.label,
      'confidence': value.confidence,
      'fallProbability': value.fallProbability,
      'updatedAt': value.updatedAt?.millisecondsSinceEpoch,
      'state': value.state.name,
      'message': value.message,
      'possibleFall': pending?['status'] == 'pending',
      'pendingFallId': pending?['status'] == 'pending'
          ? pending!['eventId']
          : null,
      'fallDeadline': pending?['status'] == 'pending'
          ? pending!['deadline']
          : null,
    });
  }

  Future<void> _beginFall(ActivitySnapshot value) async {
    _savingFall = true;
    try {
      final now = DateTime.now();
      final id = FirebaseFirestore.instance.collection('fall_events').doc().id;
      _pending = {
        'eventId': id,
        'userId': _userId,
        'deadline': now.add(const Duration(seconds: 30)).millisecondsSinceEpoch,
        'detectedAt': now.millisecondsSinceEpoch,
        'label': value.label,
        'confidence': value.confidence,
        'fallProbability': value.fallProbability,
        'status': 'pending',
      };
      // Persist locally before showing the warning, including when offline.
      await _channel.invokeMethod<void>('savePendingFall', _pending);
      if (!_ownsSession) return;
      _restorePending();
      unawaited(
        _saveFallRecord(_pending!, 'pending_confirmation').catchError(
          (Object error) => debugPrint('Fall record deferred: $error'),
        ),
      );
      await _publish();
    } finally {
      _savingFall = false;
    }
  }

  void _restorePending() {
    final value = _pending;
    if (value == null || value['userId'] != _userId || !_ownsSession) return;
    if (value['status'] == 'cancelled') {
      _pending = null;
      unawaited(_channel.invokeMethod<void>('clearPendingFall'));
      return;
    }
    if (value['status'] == 'confirmed') {
      unawaited(_deliver());
      return;
    }
    final remaining = DateTime.fromMillisecondsSinceEpoch(
      value['deadline'] as int,
    ).difference(DateTime.now());
    if (remaining <= Duration.zero) {
      unawaited(_respond(value['eventId'] as String, true));
    } else {
      unawaited(_channel.invokeMethod<void>('showFallWarning', value));
      _deadline?.cancel();
      _deadline = Timer(
        remaining,
        () => unawaited(_respond(value['eventId'] as String, true)),
      );
    }
  }

  Future<void> _respond(String id, bool send) async {
    final value = _pending;
    if (!_ownsSession ||
        value == null ||
        value['eventId'] != id ||
        value['status'] != 'pending') {
      return;
    }
    // Change state before awaiting so UI, notification and deadline cannot race.
    value['status'] = send ? 'confirmed' : 'cancelled';
    _deadline?.cancel();
    await _channel.invokeMethod<void>('savePendingFall', value);
    await _channel.invokeMethod<void>('hideFallWarning');
    _monitor.acknowledgePossibleFall();
    await _publish();
    if (send) {
      await _deliver();
    } else {
      unawaited(
        _saveFallRecord(value, 'cancelled').catchError(
          (Object error) =>
              debugPrint('Fall cancellation record deferred: $error'),
        ),
      );
      _pending = null;
      await _channel.invokeMethod<void>('clearPendingFall');
    }
  }

  Future<void> _saveFallRecord(Map<String, dynamic> value, String status) =>
      FirebaseFirestore.instance
          .collection('fall_events')
          .doc(value['eventId'] as String)
          .set({
            'elderlyId': _userId,
            'status': status,
            'activity': value['label'],
            'confidence': value['confidence'],
            'fallProbability': value['fallProbability'],
            'source': 'phone',
            'detectedAt': Timestamp.fromMillisecondsSinceEpoch(
              value['detectedAt'] as int,
            ),
            if (status != 'pending_confirmation')
              'resolvedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

  Future<void> _deliver() async {
    if (_delivering || !_ownsSession || _pending?['status'] != 'confirmed') {
      return;
    }
    _delivering = true;
    final value = _pending!;
    try {
      try {
        await _channel.invokeMethod<void>('queueFallSms');
      } on PlatformException catch (error) {
        debugPrint('Could not queue fall SMS: ${error.code}');
      }
      final profile = await FirestoreProfileRepository()
          .loadElderlyProfile(_userId)
          .timeout(const Duration(seconds: 20));
      final caregivers = await FirestoreCareLinkRepository()
          .loadLinkedCaregiverIds(_userId)
          .timeout(const Duration(seconds: 20));
      if (!_ownsSession) return;
      final id = value['eventId'] as String;
      // A stable ID prevents duplicate SOS records after a process restart.
      final alert = FirebaseFirestore.instance
          .collection('emergency_alerts')
          .doc(id);
      try {
        await alert
            .set({
              'elderlyId': _userId,
              'elderlyName': profile?.fullName ?? 'Elderly user',
              'type': 'possible_fall',
              'status': 'active',
              'activity': value['label'],
              'fallProbability': value['fallProbability'],
              'sensorSource': 'phone',
              'emergencyContactPhone': profile?.emergencyPhone ?? '',
              'recipientCaregiverIds': caregivers,
              'createdAt': Timestamp.fromMillisecondsSinceEpoch(
                value['detectedAt'] as int,
              ),
            }, SetOptions(merge: true))
            .timeout(const Duration(seconds: 20));
      } on FirebaseException catch (error) {
        if (error.code != 'permission-denied') rethrow;
        // Rules permit creation but prevent overwriting an existing alert. A
        // retry may only reuse the same phone event owned by this account.
        final existing =
            (await alert
                    .get(const GetOptions(source: Source.server))
                    .timeout(const Duration(seconds: 20)))
                .data();
        if (existing?['elderlyId'] != _userId ||
            existing?['type'] != 'possible_fall' ||
            existing?['sensorSource'] != 'phone') {
          rethrow;
        }
        if (existing?['status'] == 'resolved') {
          _pending = null;
          await _channel.invokeMethod<void>('clearPendingFall');
          return;
        }
      }
      if (!_ownsSession) return;
      final delivery = await const EmergencyPushService().send(id);
      await _saveFallRecord(
        value,
        'alert_sent',
      ).timeout(const Duration(seconds: 20));
      if (!delivery.anyChannelAccepted) {
        throw StateError('Caregiver delivery is unavailable.');
      }
      await _channel.invokeMethod<void>('deliveryStatus', {
        'eventId': id,
        'title': 'Caregiver alert submitted',
        'message': delivery.deliverySummary,
      });
      _pending = null;
      await _channel.invokeMethod<void>('clearPendingFall');
    } catch (error) {
      debugPrint('Background caregiver alert will retry: $error');
      if (_ownsSession) {
        await _channel.invokeMethod<void>('deliveryStatus', {
          'eventId': value['eventId'],
          'title': 'SOS saved — check delivery',
          'message': 'Caregiver alert pending. Check your internet connection.',
        });
        _retry?.cancel();
        _retry = Timer(
          const Duration(seconds: 30),
          () => unawaited(_deliver()),
        );
      }
    } finally {
      _delivering = false;
    }
  }
}
