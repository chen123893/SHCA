import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shca/screens/auth/elderly_profile.dart';
import 'package:shca/screens/auth/elderly_shared.dart';
import 'package:shca/services/activity_recognition_service.dart';
import 'package:shca/services/activity_status_service.dart';
import 'package:shca/services/wearable_bridge_service.dart';

class ElderlyMonitoringScreen extends StatefulWidget {
  const ElderlyMonitoringScreen({super.key, required this.activityMonitor});

  final ActivityMonitor activityMonitor;

  @override
  State<ElderlyMonitoringScreen> createState() =>
      _ElderlyMonitoringScreenState();
}

class _ElderlyMonitoringScreenState extends State<ElderlyMonitoringScreen> {
  late ActivitySnapshot _activity;
  WearableStatus _wearable = const WearableStatus();
  StreamSubscription<Map<String, dynamic>>? _wearableSubscription;

  @override
  void initState() {
    super.initState();
    _activity = widget.activityMonitor.snapshot;
    widget.activityMonitor.addListener(_refresh);
    unawaited(widget.activityMonitor.start());
    unawaited(_initializeWearable());
  }

  Future<void> _initializeWearable() async {
    final bridge = WearableBridgeService.instance;
    await bridge.initialize();
    _wearableSubscription ??= bridge.events.listen((event) {
      if (event['type'] == 'status') {
        _applyWearableStatus(WearableStatus.fromMap(event));
      }
    });
    _applyWearableStatus(await bridge.getStatus());
  }

  void _applyWearableStatus(WearableStatus status) {
    if (!mounted) return;
    setState(() => _wearable = status);
    unawaited(ActivityStatusService.instance.publishWatch(status));
  }

  void _refresh() {
    if (!mounted) return;
    setState(() => _activity = widget.activityMonitor.snapshot);
    unawaited(ActivityStatusService.instance.publishPhone(_activity));
  }

  @override
  void dispose() {
    widget.activityMonitor.removeListener(_refresh);
    unawaited(_wearableSubscription?.cancel());
    super.dispose();
  }

  void _goHome() => Navigator.pop(context);

  void _openProfile() {
    Navigator.pushReplacement<bool, void>(
      context,
      MaterialPageRoute<bool>(
        builder: (_) =>
            ElderlyProfileScreen(activityMonitor: widget.activityMonitor),
      ),
    );
  }

  Widget _deviceCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required String status,
    required Color statusColor,
  }) {
    return elderlySectionCard(
      child: Row(
        children: [
          _RoundIcon(
            icon: icon,
            background: const Color(0xFFFFE3C7),
            foreground: elderlyOrange,
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
              ],
            ),
          ),
          _StatusPill(label: status, color: statusColor),
        ],
      ),
    );
  }

  Widget _activitySourceCard({
    required String source,
    required String label,
    required double confidence,
    required DateTime? updatedAt,
    required bool active,
    required (IconData, Color, Color) appearance,
    required String inactiveMessage,
  }) {
    return elderlySectionCard(
      child: Row(
        children: [
          _RoundIcon(
            icon: appearance.$1,
            background: appearance.$2,
            foreground: appearance.$3,
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  source,
                  style: const TextStyle(
                    color: Colors.black54,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  active ? _displayActivity(label) : inactiveMessage,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  active && updatedAt != null
                      ? '${(confidence * 100).round()}% confidence • ${_formatClock(updatedAt)}'
                      : 'No live movement result',
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
              ],
            ),
          ),
          _StatusPill(
            label: active ? 'Active' : 'Off',
            color: active ? elderlyGreen : Colors.grey,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final phoneActive = _activity.state == ActivityMonitorState.active;
    final watchActive = _wearable.monitoringActive;
    final monitoringActive = phoneActive || watchActive;
    final monitoringStatus = phoneActive && watchActive
        ? '2 Active'
        : monitoringActive
        ? 'Active'
        : 'Starting';
    final monitoringColor = monitoringActive ? elderlyGreen : elderlyOrange;
    final monitoringMessage = phoneActive && watchActive
        ? 'Phone and watch are monitoring separately.'
        : phoneActive
        ? 'This phone is monitoring with its own sensors.'
        : watchActive
        ? 'The watch is monitoring with its own sensors.'
        : 'Open SHCA on either device to start its motion sensors.';
    final phoneStatus = switch (_activity.state) {
      ActivityMonitorState.active => 'Active',
      ActivityMonitorState.unavailable => 'Unavailable',
      ActivityMonitorState.stopped => 'Paused',
      _ => 'Preparing',
    };
    final phoneColor = switch (_activity.state) {
      ActivityMonitorState.active => elderlyGreen,
      ActivityMonitorState.unavailable => elderlyRed,
      _ => elderlyOrange,
    };
    final watchStatus = watchActive
        ? 'Active'
        : _wearable.connected
        ? 'App closed'
        : 'Not linked';
    final appearance = _activityAppearance(_activity.label);
    final watchAppearance = _activityAppearance(_wearable.label);

    return Scaffold(
      backgroundColor: elderlyPageBackground,
      body: SafeArea(
        child: Column(
          children: [
            ElderlyPageHeader(
              title: 'Monitoring Status',
              onProfile: _openProfile,
            ),
            Expanded(
              child: RefreshIndicator(
                color: elderlyOrange,
                onRefresh: () async {
                  await widget.activityMonitor.start();
                  _refresh();
                  _applyWearableStatus(
                    await WearableBridgeService.instance.getStatus(),
                  );
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              const Text(
                                'Monitoring Status',
                                style: TextStyle(
                                  fontSize: 23,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                monitoringMessage,
                                style: const TextStyle(color: Colors.black54),
                              ),
                            ],
                          ),
                        ),
                        _StatusPill(
                          label: monitoringStatus,
                          color: monitoringColor,
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    const _SectionTitle('Device Status'),
                    const SizedBox(height: 9),
                    _deviceCard(
                      icon: Icons.smartphone_rounded,
                      title: 'Phone Motion Sensors',
                      subtitle: 'Phone accelerometer + gyroscope • 50 Hz',
                      status: phoneStatus,
                      statusColor: phoneColor,
                    ),
                    const SizedBox(height: 10),
                    _deviceCard(
                      icon: Icons.watch_rounded,
                      title: 'Watch Motion Sensors',
                      subtitle: watchActive
                          ? 'Wrist accelerometer + gyroscope • 50 Hz'
                          : _wearable.connected
                          ? 'Linked • Open SHCA Watch to monitor'
                          : 'Optional • Pair a Wear OS watch',
                      status: watchStatus,
                      statusColor: watchActive
                          ? elderlyGreen
                          : _wearable.connected
                          ? elderlyOrange
                          : Colors.grey,
                    ),
                    const SizedBox(height: 20),
                    const _SectionTitle('Activity by Device'),
                    const SizedBox(height: 9),
                    _activitySourceCard(
                      source: 'PHONE',
                      label: _activity.label,
                      confidence: _activity.confidence,
                      updatedAt: _activity.updatedAt,
                      active: phoneActive,
                      appearance: appearance,
                      inactiveMessage: phoneStatus,
                    ),
                    const SizedBox(height: 10),
                    _activitySourceCard(
                      source: 'WATCH',
                      label: _wearable.label,
                      confidence: _wearable.confidence,
                      updatedAt: _wearable.updatedAt,
                      active: watchActive,
                      appearance: watchAppearance,
                      inactiveMessage: watchStatus,
                    ),
                    const SizedBox(height: 20),
                    const _SectionTitle('Fall Detection'),
                    const SizedBox(height: 9),
                    elderlySectionCard(
                      child: Column(
                        children: [
                          Row(
                            children: [
                              _RoundIcon(
                                icon: _activity.possibleFall
                                    ? Icons.warning_amber_rounded
                                    : Icons.health_and_safety_rounded,
                                background: _activity.possibleFall
                                    ? const Color(0xFFFFD7D2)
                                    : const Color(0xFFFFEEC8),
                                foreground: _activity.possibleFall
                                    ? elderlyRed
                                    : const Color(0xFF9B6B17),
                              ),
                              const SizedBox(width: 13),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _activity.possibleFall
                                          ? 'Possible Fall Needs Attention'
                                          : monitoringActive
                                          ? 'Auto Fall Detection Active'
                                          : _activity.state ==
                                                ActivityMonitorState.unavailable
                                          ? 'Fall Detection Unavailable'
                                          : _activity.state ==
                                                ActivityMonitorState.stopped
                                          ? 'Fall Detection Paused'
                                          : 'Preparing Fall Detection',
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      _activity.possibleFall
                                          ? 'Please confirm your safety on the home screen.'
                                          : monitoringActive
                                          ? 'Each active device checks movement with its own on-device model.'
                                          : _activity.message,
                                      style: const TextStyle(
                                        color: Colors.black54,
                                        fontSize: 12,
                                        height: 1.35,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  key: const Key('view-fall-history'),
                                  onPressed: () => Navigator.push<void>(
                                    context,
                                    MaterialPageRoute<void>(
                                      builder: (_) => FallHistoryScreen(
                                        activityMonitor: widget.activityMonitor,
                                      ),
                                    ),
                                  ),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: elderlyOrange,
                                    minimumSize: const Size(0, 48),
                                  ),
                                  icon: const Icon(Icons.history_rounded),
                                  label: const Text('View History'),
                                ),
                              ),
                              const SizedBox(width: 10),
                              _StatusPill(
                                label: _activity.possibleFall
                                    ? 'Alert'
                                    : monitoringStatus,
                                color: _activity.possibleFall
                                    ? elderlyRed
                                    : monitoringColor,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    Container(
                      padding: const EdgeInsets.all(15),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEAF4FF),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.privacy_tip_outlined,
                            color: Color(0xFF3E73A8),
                          ),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Phone and watch movement are analysed separately on each device. Raw sensor readings are not uploaded.',
                              style: TextStyle(
                                color: Color(0xFF355F89),
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: ElderlyBottomNavigation(
        selectedIndex: 2,
        onHome: _goHome,
        onMedicine: () =>
            Navigator.pushReplacementNamed(context, '/medication'),
        onMonitor: () {},
        onProfile: _openProfile,
      ),
    );
  }
}

class FallHistoryScreen extends StatefulWidget {
  const FallHistoryScreen({super.key, required this.activityMonitor});

  final ActivityMonitor activityMonitor;

  @override
  State<FallHistoryScreen> createState() => _FallHistoryScreenState();
}

class _FallHistoryScreenState extends State<FallHistoryScreen> {
  String _filter = 'all';

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return Scaffold(
      backgroundColor: elderlyPageBackground,
      appBar: AppBar(
        backgroundColor: const Color(0xFFFFB77D),
        centerTitle: true,
        title: const Text(
          'Fall History',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: uid == null
          ? const Center(child: Text('Please sign in to view fall history.'))
          : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('fall_events')
                  .where('elderlyId', isEqualTo: uid)
                  .orderBy('detectedAt', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: elderlyOrange),
                  );
                }
                if (snapshot.hasError) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Fall history could not be loaded. Please try again.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                var documents = snapshot.data?.docs.toList() ?? [];
                documents.sort((first, second) {
                  final firstTime = first.data()['detectedAt'] as Timestamp?;
                  final secondTime = second.data()['detectedAt'] as Timestamp?;
                  return (secondTime?.millisecondsSinceEpoch ?? 0).compareTo(
                    firstTime?.millisecondsSinceEpoch ?? 0,
                  );
                });
                if (_filter != 'all') {
                  documents = documents
                      .where((document) => document.data()['status'] == _filter)
                      .toList();
                }

                return ListView(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
                  children: [
                    const Text(
                      'Fall Detection Records',
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    const Text(
                      'Possible falls and the action taken afterward.',
                      style: TextStyle(color: Colors.black54),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: elderlySectionCard(
                            child: Row(
                              children: [
                                const CircleAvatar(
                                  backgroundColor: Color(0xFFFFE5CF),
                                  child: Icon(
                                    Icons.warning_amber_rounded,
                                    color: elderlyOrange,
                                  ),
                                ),
                                const SizedBox(width: 11),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${snapshot.data?.docs.length ?? 0}',
                                      style: const TextStyle(
                                        fontSize: 21,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    const Text(
                                      'Total events',
                                      style: TextStyle(color: Colors.black54),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      children: [
                        ChoiceChip(
                          label: const Text('All'),
                          selected: _filter == 'all',
                          onSelected: (_) => setState(() => _filter = 'all'),
                        ),
                        ChoiceChip(
                          label: const Text('Alert sent'),
                          selected: _filter == 'alert_sent',
                          onSelected: (_) =>
                              setState(() => _filter = 'alert_sent'),
                        ),
                        ChoiceChip(
                          label: const Text('I was safe'),
                          selected: _filter == 'cancelled',
                          onSelected: (_) =>
                              setState(() => _filter = 'cancelled'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (documents.isEmpty)
                      elderlySectionCard(
                        child: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 14),
                          child: Column(
                            children: [
                              Icon(
                                Icons.verified_user_outlined,
                                color: elderlyGreen,
                                size: 48,
                              ),
                              SizedBox(height: 9),
                              Text(
                                'No fall records',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                'Possible fall events will appear here.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.black54),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      for (final document in documents) ...[
                        _FallEventCard(data: document.data()),
                        const SizedBox(height: 11),
                      ],
                  ],
                );
              },
            ),
      bottomNavigationBar: ElderlyBottomNavigation(
        selectedIndex: 2,
        onHome: () => Navigator.popUntil(
          context,
          (route) => route.settings.name == '/home' || route.isFirst,
        ),
        onMedicine: () =>
            Navigator.pushReplacementNamed(context, '/medication'),
        onMonitor: () => Navigator.pop(context),
        onProfile: () => Navigator.push<bool>(
          context,
          MaterialPageRoute<bool>(
            builder: (_) =>
                ElderlyProfileScreen(activityMonitor: widget.activityMonitor),
          ),
        ),
      ),
    );
  }
}

class _FallEventCard extends StatelessWidget {
  const _FallEventCard({required this.data});

  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final status = (data['status'] as String?) ?? 'pending_confirmation';
    final detectedAt = (data['detectedAt'] as Timestamp?)?.toDate();
    final source = (data['source'] as String?)?.toLowerCase() ?? 'phone';
    final sourceLabel = source.contains('wear') ? 'Watch' : 'Phone';
    final cancelled = status == 'cancelled';
    final alertSent = status == 'alert_sent';
    final color = cancelled
        ? elderlyGreen
        : alertSent
        ? elderlyRed
        : elderlyOrange;
    final title = cancelled
        ? 'Possible Fall Detected'
        : alertSent
        ? 'Fall Alert Sent'
        : 'Safety Confirmation Pending';
    final subtitle = cancelled
        ? 'User confirmed they were safe.'
        : alertSent
        ? 'Emergency alert was started.'
        : 'Waiting for a safety response.';

    return elderlySectionCard(
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: color.withValues(alpha: 0.13),
            child: Icon(
              cancelled ? Icons.check_rounded : Icons.warning_amber_rounded,
              color: color,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 3),
                Text(
                  '$subtitle • Detected by $sourceLabel',
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
                if (detectedAt != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${_formatDate(detectedAt)} • ${_formatClock(detectedAt)}',
                    style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ],
            ),
          ),
          _StatusPill(
            label: cancelled
                ? 'Safe'
                : alertSent
                ? 'Sent'
                : 'Pending',
            color: color,
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
  );
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({
    required this.icon,
    required this.background,
    required this.foreground,
  });

  final IconData icon;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Container(
    width: 52,
    height: 52,
    decoration: BoxDecoration(color: background, shape: BoxShape.circle),
    child: Icon(icon, color: foreground, size: 29),
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      label,
      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w900),
    ),
  );
}

(IconData, Color, Color) _activityAppearance(String value) {
  return switch (value.trim().toLowerCase()) {
    'walking' => (
      Icons.directions_walk_rounded,
      const Color(0xFFBDEDAF),
      const Color(0xFF3F813B),
    ),
    'running' => (
      Icons.directions_run_rounded,
      const Color(0xFFFFD6A4),
      const Color(0xFFB56316),
    ),
    'active' || 'jumping' => (
      Icons.sports_gymnastics_rounded,
      const Color(0xFFDCCBFF),
      const Color(0xFF6D4CAF),
    ),
    'fall' => (
      Icons.warning_amber_rounded,
      const Color(0xFFFFC8C3),
      elderlyRed,
    ),
    _ => (
      Icons.self_improvement_rounded,
      const Color(0xFFDCEAFF),
      const Color(0xFF4E719B),
    ),
  };
}

String _displayActivity(String value) {
  return switch (value.trim().toLowerCase()) {
    'resting' || 'activity_unknown' => 'Resting / Checking',
    'walking' => 'Walking',
    'running' => 'Running',
    'active' || 'jumping' => 'Active',
    'fall' => 'Possible Fall',
    'collecting movement' => 'Collecting Movement',
    'preparing sensors' => 'Preparing Sensors',
    _ => value,
  };
}

String _formatClock(DateTime value) {
  final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute ${value.hour >= 12 ? 'PM' : 'AM'}';
}

String _formatDate(DateTime value) {
  const months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${value.day} ${months[value.month - 1]} ${value.year}';
}
