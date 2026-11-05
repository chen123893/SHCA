import 'dart:convert';
import 'package:shca/services/emergency_location_service.dart';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shca/screens/auth/elderly_monitoring.dart';
import 'package:shca/screens/auth/elderly_shared.dart';
import 'package:shca/screens/auth/elderly_profile.dart';
import 'package:shca/services/activity_recognition_service.dart';
import 'package:shca/services/phone_fall_monitor.dart';
import 'package:shca/services/activity_status_service.dart';
import 'package:shca/services/alert_vibration_service.dart';
import 'package:shca/services/care_link_service.dart';
import 'package:shca/services/emergency_push_service.dart';
import 'package:shca/services/medication_service.dart';
import 'package:shca/services/profile_service.dart';
import 'package:shca/services/push_notification_service.dart';
import 'package:shca/services/wearable_bridge_service.dart';
import 'package:shca/widgets/medication_visual.dart';
import 'package:shca/widgets/emergency_information_dialog.dart';
import 'package:url_launcher/url_launcher.dart';

enum FallSafetyResponse { safe, sendAlert }

class PossibleFallCountdownDialog extends StatefulWidget {
  const PossibleFallCountdownDialog({
    super.key,
    this.countdownDuration = const Duration(seconds: 30),
    this.deadline,
    this.manageFeedback = true,
  });

  final Duration countdownDuration;
  final DateTime? deadline;
  final bool manageFeedback;

  @override
  State<PossibleFallCountdownDialog> createState() =>
      _PossibleFallCountdownDialogState();
}

class _PossibleFallCountdownDialogState
    extends State<PossibleFallCountdownDialog> {
  static const Color _alertRed = Color(0xFFE93832);
  Timer? _timer;
  late int _remainingSeconds;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    if (widget.manageFeedback) {
      unawaited(
        AlertVibrationService.startFall(duration: widget.countdownDuration),
      );
    }
    _remainingSeconds = _secondsLeft();
    if (_remainingSeconds < 1) _remainingSeconds = 1;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _completed) return;
      if (widget.deadline != null
          ? _secondsLeft() <= 0
          : _remainingSeconds <= 1) {
        _respond(FallSafetyResponse.sendAlert);
      } else {
        setState(
          () => _remainingSeconds = widget.deadline == null
              ? _remainingSeconds - 1
              : _secondsLeft(),
        );
      }
    });
  }

  int _secondsLeft() => widget.deadline == null
      ? widget.countdownDuration.inSeconds
      : (widget.deadline!.difference(DateTime.now()).inMilliseconds / 1000)
            .ceil();

  void _respond(FallSafetyResponse response) {
    if (_completed || !mounted) return;
    _completed = true;
    _timer?.cancel();
    if (widget.manageFeedback) unawaited(AlertVibrationService.stop());
    Navigator.of(context).pop(response);
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (widget.manageFeedback) unawaited(AlertVibrationService.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: const Icon(Icons.warning_amber_rounded, color: _alertRed, size: 52),
    title: const Text(
      'Are you safe?',
      textAlign: TextAlign.center,
      style: TextStyle(fontWeight: FontWeight.w800),
    ),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'The phone detected a possible fall.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 18),
        Semantics(
          label: 'Automatic caregiver alert in $_remainingSeconds seconds',
          liveRegion: true,
          child: Container(
            width: 88,
            height: 88,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: Color(0xFFFFECE9),
              shape: BoxShape.circle,
            ),
            child: Text(
              '$_remainingSeconds',
              key: const Key('fall-countdown-seconds'),
              style: const TextStyle(
                color: _alertRed,
                fontSize: 36,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'If you do not respond, SHCA will automatically notify your linked caregiver.',
          textAlign: TextAlign.center,
          style: TextStyle(height: 1.4),
        ),
      ],
    ),
    actionsAlignment: MainAxisAlignment.center,
    actions: [
      FilledButton.tonalIcon(
        key: const Key('fall-im-safe'),
        onPressed: () => _respond(FallSafetyResponse.safe),
        icon: const Icon(Icons.check_circle_outline),
        label: const Text("I'm safe"),
      ),
      FilledButton.icon(
        key: const Key('fall-send-now'),
        style: FilledButton.styleFrom(backgroundColor: _alertRed),
        onPressed: () => _respond(FallSafetyResponse.sendAlert),
        icon: const Icon(Icons.sos),
        label: const Text('Send alert now'),
      ),
    ],
  );
}

class ElderlyHomeScreen extends StatefulWidget {
  const ElderlyHomeScreen({
    super.key,
    this.activityMonitor,
    this.profileRepository,
    this.careLinkRepository,
    this.loadRemoteProfile = true,
    this.initialName = 'User',
  });

  final ActivityMonitor? activityMonitor;
  final ProfileRepository? profileRepository;
  final CareLinkRepository? careLinkRepository;
  final bool loadRemoteProfile;
  final String initialName;

  @override
  State<ElderlyHomeScreen> createState() => _ElderlyHomeScreenState();
}

class _ElderlyHomeScreenState extends State<ElderlyHomeScreen>
    with SingleTickerProviderStateMixin {
  static const Color _pageBackground = Color(0xFFFFF8F0);
  static const Color _orange = Color(0xFFFF8128);
  static const Color _ink = Color(0xFF241D19);
  static const Color _green = Color(0xFF4F9A4B);
  static const Color _red = Color(0xFFE93832);

  final ScrollController _scrollController = ScrollController();
  final GlobalKey _medicationKey = GlobalKey();
  late final AnimationController _sosHoldController;
  late final ActivityMonitor _activityMonitor;
  late final bool _ownsActivityMonitor;
  late final ProfileRepository _profileRepository;
  late final CareLinkRepository _careLinkRepository;

  ActivitySnapshot _activity = const ActivitySnapshot();
  WearableStatus _wearable = const WearableStatus();
  String _userName = 'User';
  String _emergencyPhone = '';
  String _medicalCondition = '';
  List<String> _linkedCaregiverIds = const <String>[];
  bool _isLoadingProfile = true;
  bool _isSendingSos = false;
  bool _fallDialogOpen = false;
  bool _monitoringBusy = false;
  String? _lastBackgroundDeliveryId;
  String? _lastMedicationAlarmSignature;
  Future<DocumentReference<Map<String, dynamic>>?>? _activeFallEvent;
  ActivitySnapshot? _pendingFallSnapshot;
  StreamSubscription<Map<String, dynamic>>? _wearableSubscription;
  Stream<QuerySnapshot<Map<String, dynamic>>>? _medicationStream;
  Timer? _wearableRefreshTimer;
  DateTime? _lastAutomaticEmergency;

  @override
  void initState() {
    super.initState();
    _userName = widget.initialName;
    _ownsActivityMonitor = widget.activityMonitor == null;
    _activityMonitor = widget.activityMonitor ?? phoneActivityMonitor();
    _activity = _activityMonitor.snapshot;
    _activityMonitor.addListener(_onActivityChanged);
    unawaited(_activityMonitor.start());

    _sosHoldController =
        AnimationController(vsync: this, duration: const Duration(seconds: 3))
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed) {
              unawaited(_triggerSos(source: 'manual_sos'));
            }
          });

    if (widget.loadRemoteProfile) {
      _setMedicationStream(FirebaseAuth.instance.currentUser?.uid);
      _profileRepository =
          widget.profileRepository ?? FirestoreProfileRepository();
      _careLinkRepository =
          widget.careLinkRepository ?? FirestoreCareLinkRepository();
      unawaited(_loadUserData().whenComplete(_initializeWearable));
    } else {
      _isLoadingProfile = false;
      unawaited(_initializeWearable());
    }
  }

  void _setMedicationStream(String? elderlyId) {
    if (elderlyId == null || elderlyId.isEmpty || _medicationStream != null) {
      return;
    }
    // Keep one stable Firestore subscription for the lifetime of this screen.
    // Activity inference rebuilds the dashboard frequently; constructing a new
    // snapshots() stream inside build briefly returned ConnectionState.waiting
    // and made the medication rows flash empty between sensor updates.
    _medicationStream = FirebaseFirestore.instance
        .collection('medications')
        .where('elderlyId', isEqualTo: elderlyId)
        .snapshots();
  }

  Future<void> _initializeWearable() async {
    final bridge = WearableBridgeService.instance;
    await bridge.initialize();
    _wearableSubscription ??= bridge.events.listen(_onWearableEvent);
    final status = await bridge.getStatus();
    _applyWearableStatus(status);
    _wearableRefreshTimer ??= Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(bridge.getStatus().then(_applyWearableStatus)),
    );
  }

  Future<void> _refreshPage() async {
    await Future.wait<void>(<Future<void>>[
      _loadUserData(),
      WearableBridgeService.instance.getStatus().then(_applyWearableStatus),
    ]);
  }

  Future<void> _onWearableEvent(Map<String, dynamic> event) async {
    if (!mounted) return;
    switch (event['type']) {
      case 'status':
        _applyWearableStatus(WearableStatus.fromMap(event));
        return;
    }
  }

  void _applyWearableStatus(WearableStatus status) {
    if (!mounted) return;
    setState(() => _wearable = status);
    unawaited(ActivityStatusService.instance.publishWatch(status));
  }

  Future<void> _loadUserData() async {
    if (!widget.loadRemoteProfile) return;
    if (mounted) setState(() => _isLoadingProfile = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      _setMedicationStream(uid);
      final results = await Future.wait<Object?>(<Future<Object?>>[
        FirebaseFirestore.instance.collection('users').doc(uid).get(),
        _profileRepository.loadElderlyProfile(uid),
        _careLinkRepository.loadLinkedCaregiverIds(uid),
      ]);
      final document = results[0] as DocumentSnapshot<Map<String, dynamic>>;
      final profile = results[1] as ElderlyProfile?;
      final caregiverIds = results[2] as List<String>;
      final data = document.data();
      if (!mounted || data == null) return;
      setState(() {
        _userName = (data['fullName'] as String?)?.trim().isNotEmpty == true
            ? data['fullName'] as String
            : ((data['email'] as String?)?.split('@').first ?? 'User');
        _emergencyPhone = profile?.emergencyPhone ?? '';
        _medicalCondition = profile?.medicalCondition ?? '';
        _linkedCaregiverIds = caregiverIds;
      });
    } catch (error) {
      debugPrint('Error loading elderly profile: $error');
    } finally {
      if (mounted) setState(() => _isLoadingProfile = false);
    }
  }

  void _syncMedicationAlarms(List<MedicationSchedule> schedules) {
    final elderlyId = FirebaseAuth.instance.currentUser?.uid;
    if (elderlyId == null) return;
    final signature = schedules
        .map(
          (item) =>
              '${item.id}:${item.hour}:${item.minute}:${item.name}:${item.dose}:${item.effectiveQuantity}:${item.instruction}:${item.recurrence.name}:${item.startDate}:${item.endDate}:${item.weekdays.join(',')}:${item.intervalDays}',
        )
        .join('|');
    if (signature == _lastMedicationAlarmSignature) return;
    _lastMedicationAlarmSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        PushNotificationService.instance.syncMedicationReminders(
          elderlyId: elderlyId,
          schedules: schedules,
        ),
      );
    });
  }

  void _onActivityChanged() {
    if (!mounted) return;
    final next = _activityMonitor.snapshot;
    setState(() => _activity = next);
    final monitor = _activityMonitor;
    if (monitor is PhoneFallMonitor) {
      final deliveryId = monitor.deliveryEventId;
      if (deliveryId != null &&
          deliveryId != _lastBackgroundDeliveryId &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        _lastBackgroundDeliveryId = deliveryId;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_showBackgroundFallResult(monitor));
        });
      }
    }
    unawaited(ActivityStatusService.instance.publishPhone(next));
    if (next.possibleFall &&
        !_fallDialogOpen &&
        _activityMonitor is! PhoneFallMonitor) {
      _pendingFallSnapshot ??= next;
      if (_activityMonitor is! PhoneFallMonitor) {
        _activeFallEvent ??= _recordPossibleFall(next);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_showPossibleFallDialog());
      });
    }
  }

  Future<DocumentReference<Map<String, dynamic>>?> _recordPossibleFall(
    ActivitySnapshot snapshot,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    try {
      return await FirebaseFirestore.instance.collection('fall_events').add({
        'elderlyId': user.uid,
        'status': 'pending_confirmation',
        'activity': snapshot.label,
        'confidence': snapshot.confidence,
        'fallProbability': snapshot.fallProbability,
        'source': 'phone',
        'detectedAt': FieldValue.serverTimestamp(),
      });
    } catch (error) {
      debugPrint('Could not save fall event: $error');
      return null;
    }
  }

  void _finishFallEvent(String status) {
    final event = _activeFallEvent;
    _activeFallEvent = null;
    if (event == null) return;
    unawaited(_updateFallEvent(event, status));
  }

  Future<void> _updateFallEvent(
    Future<DocumentReference<Map<String, dynamic>>?> event,
    String status,
  ) async {
    try {
      final reference = await event;
      if (reference == null) return;
      await reference.update({
        'status': status,
        'resolvedAt': FieldValue.serverTimestamp(),
      });
    } catch (error) {
      debugPrint('Could not update fall event: $error');
    }
  }

  Future<void> _showPossibleFallDialog() async {
    if (_fallDialogOpen) return;
    _fallDialogOpen = true;
    final detectedFall = _pendingFallSnapshot ?? _activity;
    FallSafetyResponse? response;
    try {
      response = await showDialog<FallSafetyResponse>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const PossibleFallCountdownDialog(),
      );
    } finally {
      _fallDialogOpen = false;
    }
    _pendingFallSnapshot = null;
    if (response == null) return;
    _activityMonitor.acknowledgePossibleFall();
    if (response == FallSafetyResponse.safe) {
      _finishFallEvent('cancelled');
      return;
    }
    _finishFallEvent('alert_sent');
    unawaited(
      _triggerSos(
        source: 'possible_fall',
        activityLabel: detectedFall.label,
        fallProbability: detectedFall.fallProbability,
      ),
    );
  }

  Future<void> _showBackgroundFallResult(PhoneFallMonitor monitor) async {
    final title = monitor.deliveryTitle ?? 'SOS saved — check delivery';
    final message =
        monitor.deliveryMessage ?? 'Check caregiver alert delivery.';
    final phone = _emergencyPhone.trim();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => EmergencyInformationDialog(
        personName: _userName,
        medicalCondition: _medicalCondition,
        emergencyPhone: phone,
        onCall: phone.isEmpty ? null : () => _openEmergencyDialler(phone),
        deliveryTitle: title,
        deliveryMessage: message,
      ),
    );
  }

  Future<void> _triggerSos({
    required String source,
    String? activityLabel,
    double? fallProbability,
  }) async {
    if (_isSendingSos) return;
    final isAutomatic = source == 'possible_fall' || source == 'wearable_fall';
    final previousAutomatic = _lastAutomaticEmergency;
    if (isAutomatic &&
        previousAutomatic != null &&
        DateTime.now().difference(previousAutomatic) <
            const Duration(seconds: 30)) {
      return;
    }
    if (isAutomatic) _lastAutomaticEmergency = DateTime.now();
    _sosHoldController.reset();
    setState(() => _isSendingSos = true);
    try {
      final phone = _emergencyPhone.trim();
      final user = FirebaseAuth.instance.currentUser;
      Object? recordError;
      EmergencyPushResult? pushResult;
      Future<EmergencyPushResult>? pushFuture;
      Future<bool>? smsFuture;
      final alert = user == null
          ? null
          : FirebaseFirestore.instance.collection('emergency_alerts').doc();
      Future<({bool callRequested, bool diallerOpened})> contact() async {
        if (phone.isEmpty) return (callRequested: false, diallerOpened: false);
        if (await _invokeSosAction('callContact', {'phone': phone})) {
          return (callRequested: true, diallerOpened: false);
        }
        try {
          final opened = await _openEmergencyDialler(phone);
          return (callRequested: false, diallerOpened: opened);
        } catch (_) {
          return (callRequested: false, diallerOpened: false);
        }
      }

      final callFuture = contact();
      final location = await EmergencyLocationService.capture();
      if (FirebaseAuth.instance.currentUser?.uid != user?.uid) return;
      if (alert != null) {
        smsFuture = _invokeSosAction('queueSms', {
          'eventId': alert.id,
          'manualSos': !isAutomatic,
          if (location != null) 'locationJson': jsonEncode(location),
        });
      }
      if (user != null && alert != null) {
        try {
          await alert
              .set({
                'elderlyId': user.uid,
                'elderlyName': _userName,
                'type': source,
                'status': 'active',
                'activity': activityLabel ?? _activity.label,
                'fallProbability': fallProbability ?? _activity.fallProbability,
                'sensorSource': source.startsWith('wearable_')
                    ? 'watch'
                    : 'phone',
                'emergencyContactPhone': phone,
                if (location != null) 'location': location,
                'recipientCaregiverIds': _linkedCaregiverIds,
                'createdAt': FieldValue.serverTimestamp(),
              })
              .timeout(const Duration(seconds: 15));
          pushFuture = const EmergencyPushService().send(alert.id);
        } catch (error) {
          recordError = error;
        }
      } else {
        recordError = StateError('Sign in is required to notify caregivers.');
      }

      final call = await callFuture;
      final smsQueued = await smsFuture ?? false;
      if (pushFuture != null) pushResult = await pushFuture;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => EmergencyInformationDialog(
          personName: _userName,
          medicalCondition: _medicalCondition,
          emergencyPhone: phone,
          onCall: phone.isEmpty ? null : () => _openEmergencyDialler(phone),
          deliveryTitle: recordError != null
              ? 'SOS needs attention'
              : pushResult?.anyChannelAccepted == true
              ? 'Caregiver alert submitted'
              : 'SOS saved — check delivery',
          deliveryMessage: [
            if (phone.isEmpty) 'No emergency contact number is set.',
            if (call.callRequested)
              'Call requested for your emergency contact.',
            if (call.diallerOpened) 'Tap Call in the phone dialler.',
            if (phone.isNotEmpty && !call.callRequested && !call.diallerOpened)
              'The phone app could not be opened.',
            if (smsQueued) 'Caregiver SMS queued.',
            if (recordError == null)
              pushResult?.deliverySummary ??
                  'Caregiver notification acceptance could not be confirmed.'
            else
              'The online SOS record could not be confirmed. Check your internet connection.',
          ].join('\n\n'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: _red,
          content: Text('Alert was not sent: $error'),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSendingSos = false);
    }
  }

  Future<bool> _invokeSosAction(
    String method,
    Map<String, Object> arguments,
  ) async {
    try {
      return await const MethodChannel(
            'com.shca.shca/sos',
          ).invokeMethod<bool>(method, arguments) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> _openEmergencyDialler(String phone) => launchUrl(
    Uri(scheme: 'tel', path: phone.replaceAll(RegExp(r'[^0-9+]'), '')),
    mode: LaunchMode.externalApplication,
  );

  @override
  void dispose() {
    _wearableRefreshTimer?.cancel();
    unawaited(_wearableSubscription?.cancel());
    _activityMonitor.removeListener(_onActivityChanged);
    if (_ownsActivityMonitor && _activityMonitor is! PhoneFallMonitor) {
      unawaited(_activityMonitor.stop());
    }
    _sosHoldController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _pageBackground,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: RefreshIndicator(
                color: _orange,
                onRefresh: _refreshPage,
                child: SingleChildScrollView(
                  controller: _scrollController,
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_greeting()}, $_userName',
                        style: const TextStyle(
                          color: _ink,
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.4,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        _isLoadingProfile
                            ? 'Updating your dashboard…'
                            : 'Here is your health overview for today.',
                        style: const TextStyle(
                          color: Color(0xFF746A64),
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildActivityCard(),
                      const SizedBox(height: 18),
                      _buildSosCard(),
                      const SizedBox(height: 18),
                      KeyedSubtree(
                        key: _medicationKey,
                        child: _buildMedicationCard(),
                      ),
                      const SizedBox(height: 18),
                      _buildHealthSummary(),
                      const SizedBox(height: 18),
                      OutlinedButton.icon(
                        onPressed: () =>
                            Navigator.pushNamed(context, '/knowledge'),
                        icon: const Icon(Icons.menu_book_rounded),
                        label: const Text('Knowledge & prevention'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _buildBottomNavigation(),
    );
  }

  Widget _buildHeader() => ElderlyPageHeader(
    title: 'Elderly Dashboard',
    onProfile: _openProfileScreen,
  );

  Future<void> _toggleFallDetection() async {
    if (_monitoringBusy) return;
    setState(() => _monitoringBusy = true);
    try {
      final monitor = _activityMonitor;
      if (monitor is PhoneFallMonitor) {
        await monitor.setEnabled(!monitor.enabled);
      } else if (_activity.state == ActivityMonitorState.stopped ||
          _activity.state == ActivityMonitorState.unavailable) {
        await monitor.start();
      } else {
        await monitor.stop();
      }
      if (mounted) setState(() => _activity = monitor.snapshot);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is PlatformException
                  ? error.message ?? 'Could not change fall detection.'
                  : 'Could not change fall detection. Please try again.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _monitoringBusy = false);
    }
  }

  Widget _buildActivityCard() {
    final monitor = _activityMonitor;
    final detectionOn = monitor is PhoneFallMonitor
        ? monitor.enabled
        : _activity.state != ActivityMonitorState.stopped &&
              _activity.state != ActivityMonitorState.unavailable;
    final appearance = _appearanceFor(_activity.label);
    final isActive = _activity.state == ActivityMonitorState.active;
    final isUnavailable =
        _activity.state == ActivityMonitorState.unavailable ||
        _activity.state == ActivityMonitorState.stopped;
    final isFall = _normaliseLabel(_activity.label) == 'fall';
    final isUncertain = _normaliseLabel(_activity.label) == 'activity_unknown';
    final statusColor = isFall
        ? _red
        : isUncertain
        ? _orange
        : isUnavailable
        ? const Color(0xFF8A817C)
        : _green;
    final statusText = isFall
        ? 'Check safety'
        : isUncertain
        ? 'Checking'
        : isUnavailable
        ? (_activity.state == ActivityMonitorState.stopped
              ? 'Off'
              : 'Unavailable')
        : isActive
        ? 'Safe'
        : 'Starting';

    return _sectionCard(
      onTap: _showActivityDetails,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Phone Activity',
                  style: TextStyle(
                    color: _ink,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: isUnavailable
                      ? const Color(0xFFF0ECE9)
                      : const Color(0xFFE8F7E2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isActive ? 'Phone active' : statusText,
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 15),
          Row(
            children: [
              Container(
                width: 116,
                height: 104,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[
                      appearance.background,
                      appearance.background.withValues(alpha: 0.55),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned(
                      right: 9,
                      top: 10,
                      child: Icon(
                        Icons.wb_sunny_rounded,
                        color: const Color(0xFFFFC54D).withValues(alpha: 0.9),
                        size: 25,
                      ),
                    ),
                    Positioned(
                      left: 7,
                      bottom: 5,
                      child: Icon(
                        Icons.park_rounded,
                        color: const Color(0xFF78A957).withValues(alpha: 0.85),
                        size: 44,
                      ),
                    ),
                    Container(
                      width: 62,
                      height: 62,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.90),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        appearance.icon,
                        color: appearance.foreground,
                        size: 40,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 43,
                          height: 43,
                          decoration: BoxDecoration(
                            color: appearance.background,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            appearance.icon,
                            color: appearance.foreground,
                            size: 27,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _displayActivity(_activity.label),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isFall ? _red : _ink,
                              fontSize: 22,
                              height: 1.05,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 11),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isFall
                                ? Icons.warning_amber_rounded
                                : isUnavailable
                                ? Icons.sensors_off_rounded
                                : Icons.verified_rounded,
                            size: 17,
                            color: statusColor,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            statusText,
                            style: TextStyle(
                              color: statusColor,
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      isActive
                          ? '${(_activity.confidence * 100).round()}% confidence • '
                                '${_formatUpdatedAt(_activity.updatedAt)}'
                          : _activity.message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF716965),
                        fontSize: 10.5,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('phone-fall-detection-toggle'),
              onPressed: _monitoringBusy ? null : _toggleFallDetection,
              icon: Icon(
                detectionOn
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline,
              ),
              label: Text(
                _monitoringBusy
                    ? 'Please wait…'
                    : detectionOn
                    ? 'Turn off fall detection'
                    : 'Turn on fall detection',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSosCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFFFF4F37), Color(0xFFE9202B)],
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: _red.withValues(alpha: 0.25),
            blurRadius: 14,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: Column(
        children: [
          const Text(
            'Emergency Help',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            _isSendingSos
                ? 'Sending your alert…'
                : 'Press and hold the SOS button for 3 seconds',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.88),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          Semantics(
            button: true,
            label: 'Emergency SOS. Press and hold for 3 seconds.',
            child: Listener(
              onPointerDown: (_) {
                if (!_isSendingSos) _sosHoldController.forward(from: 0);
              },
              onPointerUp: (_) {
                if (!_sosHoldController.isCompleted) {
                  _sosHoldController.reverse();
                }
              },
              onPointerCancel: (_) => _sosHoldController.reverse(),
              child: AnimatedBuilder(
                animation: _sosHoldController,
                builder: (context, child) => Container(
                  width: 176,
                  height: 176,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CircularProgressIndicator(
                        value: _sosHoldController.value,
                        strokeWidth: 9,
                        backgroundColor: Colors.white.withValues(alpha: 0.86),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFFFFC2B9),
                        ),
                      ),
                      Container(
                        margin: const EdgeInsets.all(15),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: <Color>[
                              Color(0xFFFF9A82),
                              Color(0xFFFF696D),
                            ],
                          ),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: _isSendingSos
                              ? const CircularProgressIndicator(
                                  color: Colors.white,
                                )
                              : const Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      'SOS',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 31,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    Text(
                                      'Hold 3 seconds',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.shield_outlined,
                color: Colors.white.withValues(alpha: 0.86),
                size: 16,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'Hold to call your emergency contact and alert caregivers',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.90),
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMedicationCard() {
    return _sectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Medication Reminders',
                  style: TextStyle(
                    color: _ink,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pushNamed(context, '/medication'),
                child: const Text('View all'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (!widget.loadRemoteProfile)
            _emptyMedicationMessage()
          else
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _medicationStream,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(color: _orange),
                    ),
                  );
                }
                if (snapshot.hasError) {
                  return const Text(
                    'Medication could not be loaded. Pull down to try again.',
                    style: TextStyle(color: Colors.black54),
                  );
                }
                final allSchedules =
                    (snapshot.data?.docs ?? const [])
                        .where(
                          (document) =>
                              document.data()['active'] != false &&
                              !isLegacyDemoMedicationData(document.data()),
                        )
                        .map(
                          (document) =>
                              MedicationSchedule.fromFirestore(document.data()),
                        )
                        .where((schedule) => schedule.id.isNotEmpty)
                        .toList()
                      ..sort(
                        (first, second) => (first.hour * 60 + first.minute)
                            .compareTo(second.hour * 60 + second.minute),
                      );
                _syncMedicationAlarms(allSchedules);
                final schedules = allSchedules
                    .where((schedule) => schedule.isScheduledOn(DateTime.now()))
                    .toList(growable: false);
                if (schedules.isEmpty) return _emptyMedicationMessage();
                return Column(
                  children: [
                    for (
                      var index = 0;
                      index < schedules.length && index < 2;
                      index++
                    ) ...[
                      _medicationRow(schedules[index]),
                      if (index < schedules.length - 1 && index < 1)
                        const Divider(height: 22),
                    ],
                  ],
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _emptyMedicationMessage() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: Color(0xFFFFE5CF),
            child: Icon(Icons.medication_outlined, color: _orange),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'No medication scheduled. Your caregiver can add one for you.',
              style: TextStyle(color: Color(0xFF716965), height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _medicationRow(MedicationSchedule medication) {
    final hour = medication.hour % 12 == 0 ? 12 : medication.hour % 12;
    final minute = medication.minute.toString().padLeft(2, '0');
    final suffix = medication.hour < 12 ? 'AM' : 'PM';
    return Row(
      children: [
        MedicationVisual(medication: medication, size: 46),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                medication.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${medication.doseSummary} • ${medication.instruction}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF716965),
                  fontSize: 10.5,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Row(
          children: [
            const Icon(Icons.schedule_rounded, color: _red, size: 15),
            const SizedBox(width: 3),
            Text(
              medication.hasAutomaticReminder
                  ? medication.timesPerDay == 1
                        ? '$hour:$minute $suffix'
                        : '${medication.timesPerDay}× daily'
                  : 'No alarm',
              style: const TextStyle(
                color: _red,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildHealthSummary() {
    final monitoringActive = _activity.state == ActivityMonitorState.active;
    final watchActive = _wearable.monitoringActive;
    final monitorStatus = switch (_activity.state) {
      ActivityMonitorState.active => 'Active',
      ActivityMonitorState.unavailable => 'Unavailable',
      ActivityMonitorState.stopped => 'Paused',
      _ => 'Starting',
    };
    final monitorColor = switch (_activity.state) {
      ActivityMonitorState.active => _green,
      ActivityMonitorState.unavailable => _red,
      _ => const Color(0xFFEF7D4B),
    };
    final monitorBackground = switch (_activity.state) {
      ActivityMonitorState.active => const Color(0xFFD9F2D0),
      ActivityMonitorState.unavailable => const Color(0xFFFFD4D1),
      _ => const Color(0xFFFFD8C8),
    };
    return _sectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Health Summary',
            style: TextStyle(
              color: _ink,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),
          IntrinsicHeight(
            child: Row(
              children: [
                Expanded(
                  child: _summaryItem(
                    icon: Icons.phone_android_rounded,
                    iconColor: monitorColor,
                    iconBackground: monitorBackground,
                    title: 'Phone Sensor',
                    value: monitorStatus,
                    caption: monitoringActive
                        ? '50 Hz motion data'
                        : 'Checking sensors',
                  ),
                ),
                const VerticalDivider(width: 18),
                Expanded(
                  child: _summaryItem(
                    icon: Icons.watch_rounded,
                    iconColor: watchActive
                        ? const Color(0xFF4B87D8)
                        : const Color(0xFF8A817C),
                    iconBackground: watchActive
                        ? const Color(0xFFD5E7FF)
                        : const Color(0xFFF0ECE9),
                    title: 'Watch Sensor',
                    value: watchActive
                        ? 'Active'
                        : _wearable.connected
                        ? 'App closed'
                        : 'Not linked',
                    caption: watchActive
                        ? 'Separate wrist AI'
                        : _wearable.connected
                        ? 'Open watch app'
                        : 'Optional device',
                  ),
                ),
                const VerticalDivider(width: 18),
                Expanded(
                  child: _summaryItem(
                    icon: _activity.possibleFall
                        ? Icons.warning_amber_rounded
                        : Icons.notifications_none_rounded,
                    iconColor: _activity.possibleFall ? _red : _green,
                    iconBackground: _activity.possibleFall
                        ? const Color(0xFFFFD4D1)
                        : const Color(0xFFD9F2D0),
                    title: 'Safety',
                    value: _activity.possibleFall ? 'Check now' : 'No alerts',
                    caption: 'Fall protection',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryItem({
    required IconData icon,
    required Color iconColor,
    required Color iconBackground,
    required String title,
    required String value,
    required String caption,
  }) {
    return Column(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: iconBackground,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: iconColor, size: 24),
        ),
        const SizedBox(height: 7),
        Text(
          title,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFF554C47),
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          value,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: iconColor,
            fontSize: 11.5,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          caption,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Color(0xFF918984), fontSize: 8.5),
        ),
      ],
    );
  }

  Widget _sectionCard({required Widget child, VoidCallback? onTap}) {
    final content = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE2DAD4)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: const Color(0xFF5A3D2C).withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: content,
    );
  }

  Widget _buildBottomNavigation() => ElderlyBottomNavigation(
    selectedIndex: 0,
    onHome: () => _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
    ),
    onMedicine: () => Navigator.pushNamed(context, '/medication'),
    onMonitor: _openMonitoringScreen,
    onProfile: _openProfileScreen,
  );

  Future<void> _showActivityDetails() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Live Activity Recognition',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 10),
            Text(_activity.message),
            const SizedBox(height: 18),
            const Text(
              'This result comes only from the phone sensors. The '
              'orientation-independent phone model shows Resting, Walking, '
              'Running, Active and possible falls. It uses motion magnitudes so '
              'rotating the phone does not change the activity. Sleeping needs a '
              'separately trained lying/sleeping class. Results update '
              'every 1.28 seconds after the first 2.56-second window.',
              style: TextStyle(height: 1.45),
            ),
          ],
        ),
      ),
    );
  }

  void _openMonitoringScreen() {
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            ElderlyMonitoringScreen(activityMonitor: _activityMonitor),
      ),
    );
  }

  Future<void> _openProfileScreen() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute<bool>(
        builder: (_) => ElderlyProfileScreen(
          activityMonitor: _activityMonitor,
          profileRepository: widget.profileRepository,
          careLinkRepository: widget.careLinkRepository,
        ),
      ),
    );
    if (changed == true && mounted) await _loadUserData();
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  String _normaliseLabel(String value) => value.trim().toLowerCase();

  String _displayActivity(String value) {
    final normalized = _normaliseLabel(value);
    const labels = <String, String>{
      'standing': 'Standing',
      'resting': 'Resting',
      'walking': 'Walking',
      'running': 'Running',
      'active': 'Active',
      'jumping': 'Jumping',
      'chair_transition': 'Sitting',
      'activity_unknown': 'Resting / Checking',
      'crouching': 'Crouching',
      'stumble': 'Stumbling',
      'hand_activity': 'Hand Activity',
      'fall': 'Possible Fall',
      'preparing sensors': 'Preparing Sensors',
      'collecting movement': 'Collecting Movement',
      'monitoring unavailable': 'Unavailable',
      'sensor unavailable': 'Unavailable',
      'monitoring paused': 'Paused',
    };
    return labels[normalized] ?? value;
  }

  _ActivityAppearance _appearanceFor(String value) {
    switch (_normaliseLabel(value)) {
      case 'walking':
        return const _ActivityAppearance(
          Icons.directions_walk_rounded,
          Color(0xFFBDEDAF),
          Color(0xFF3F813B),
        );
      case 'running':
        return const _ActivityAppearance(
          Icons.directions_run_rounded,
          Color(0xFFFFD6A4),
          Color(0xFFB56316),
        );
      case 'jumping':
      case 'active':
        return const _ActivityAppearance(
          Icons.sports_gymnastics_rounded,
          Color(0xFFDCCBFF),
          Color(0xFF6D4CAF),
        );
      case 'standing':
        return const _ActivityAppearance(
          Icons.accessibility_new_rounded,
          Color(0xFFCAE7FF),
          Color(0xFF3D79AE),
        );
      case 'chair_transition':
        return const _ActivityAppearance(
          Icons.airline_seat_recline_normal_rounded,
          Color(0xFFFFDFC4),
          Color(0xFFAF642A),
        );
      case 'activity_unknown':
        return const _ActivityAppearance(
          Icons.self_improvement_rounded,
          Color(0xFFFFE8C8),
          Color(0xFF9A681F),
        );
      case 'resting':
        return const _ActivityAppearance(
          Icons.self_improvement_rounded,
          Color(0xFFDCEAFF),
          Color(0xFF4E719B),
        );
      case 'fall':
        return const _ActivityAppearance(
          Icons.warning_amber_rounded,
          Color(0xFFFFC8C3),
          _red,
        );
      default:
        return const _ActivityAppearance(
          Icons.sensors_rounded,
          Color(0xFFE7E1DD),
          Color(0xFF746A64),
        );
    }
  }

  String _formatUpdatedAt(DateTime? dateTime) {
    if (dateTime == null) return 'waiting for first result';
    return 'updated ${_formatClock(dateTime)}';
  }

  String _formatClock(DateTime dateTime) {
    final hour = dateTime.hour % 12 == 0 ? 12 : dateTime.hour % 12;
    final minute = dateTime.minute.toString().padLeft(2, '0');
    final period = dateTime.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
  }
}

@immutable
class _ActivityAppearance {
  const _ActivityAppearance(this.icon, this.background, this.foreground);

  final IconData icon;
  final Color background;
  final Color foreground;
}
