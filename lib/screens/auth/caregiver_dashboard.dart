import 'package:shca/widgets/alert_location_card.dart';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shca/screens/auth/caregiver_medication_schedule.dart';
import 'package:shca/screens/auth/caregiver_shared.dart';
import 'package:shca/screens/auth/link_elderly.dart';
import 'package:shca/services/care_link_service.dart';
import 'package:shca/services/caregiver_alert_service.dart';
import 'package:shca/services/medication_service.dart';
import 'package:shca/services/profile_service.dart';
import 'package:shca/services/push_notification_service.dart';

const _background = Color(0xFFFFF8F0);
const _header = Color(0xFFFFB87D);
const _orange = Color(0xFFFF7518);
const _amber = Color(0xFFF5A000);
const _ink = Color(0xFF2B2521);
const _green = Color(0xFF279D68);
const _red = Color(0xFFE83C36);
const _border = Color(0xFFF0D7C4);

/// Caregiver dashboard based on the Figma prototype.
///
/// Only caregiver-readable Firestore data is displayed as a remote status.
/// Live activity classification remains on the elderly device until the user
/// explicitly opts into a future activity-sharing feature.
class CaregiverDashboardScreen extends StatefulWidget {
  const CaregiverDashboardScreen({super.key, this.repository});

  final CareLinkRepository? repository;

  @override
  State<CaregiverDashboardScreen> createState() =>
      _CaregiverDashboardScreenState();
}

class _CaregiverDashboardScreenState extends State<CaregiverDashboardScreen> {
  late final CareLinkRepository _repository;
  Future<List<LinkedElderly>>? _linkedFuture;
  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>>? _emergencyAlerts;
  List<LinkedElderly> _linkedElderly = const [];
  String _caregiverName = 'Caregiver';
  String? _caregiverId;
  int _refreshVersion = 0;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? FirestoreCareLinkRepository();
    unawaited(_load());
  }

  Future<void> _load() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final results = await Future.wait<Object?>([
        FirebaseFirestore.instance.collection('users').doc(user.uid).get(),
        FirestoreProfileRepository().loadCaregiverProfile(user.uid),
      ]);
      final userDocument = results[0] as DocumentSnapshot<Map<String, dynamic>>;
      final caregiverProfile = results[1] as CaregiverProfile?;
      final name = (userDocument.data()?['fullName'] as String?)?.trim();
      if (caregiverProfile?.pushAlert ?? true) {
        unawaited(PushNotificationService.instance.registerCaregiver(user.uid));
      } else {
        unawaited(PushNotificationService.instance.unregisterCaregiver());
      }
      if (!mounted) return;
      setState(() {
        _caregiverId = user.uid;
        if (name != null && name.isNotEmpty) _caregiverName = name;
        _setLinkedFuture(user.uid, _loadLinked(user.uid));
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _caregiverId = user.uid;
        _setLinkedFuture(user.uid, Future<List<LinkedElderly>>.error(error));
      });
    }
  }

  Future<List<LinkedElderly>> _loadLinked(String caregiverId) async {
    final linked = await _repository.loadLinkedElderly(caregiverId);
    if (mounted) setState(() => _linkedElderly = linked);
    return linked;
  }

  void _setLinkedFuture(
    String caregiverId,
    Future<List<LinkedElderly>> linked,
  ) {
    _linkedFuture = linked;
    _emergencyAlerts = watchCaregiverEmergencyAlerts(
      caregiverId: caregiverId,
      elderlyIds: linked.then((people) => people.map((person) => person.id)),
      limitPerElderly: 30,
    );
  }

  Future<void> _refresh() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    setState(() {
      _refreshVersion++;
      _setLinkedFuture(uid, _loadLinked(uid));
    });
    await _linkedFuture;
  }

  Future<void> _openLinkElderly() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => const LinkElderlyScreen()),
    );
    if (mounted) await _refresh();
  }

  void _openStatus(LinkedElderly elderly) {
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => CaregiverElderlyStatusScreen(
          elderly: elderly,
          linkedElderly: _linkedElderly,
        ),
      ),
    );
  }

  void _openMedication(LinkedElderly elderly) {
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => CaregiverMedicationScheduleScreen(
          elderly: elderly,
          linkedElderly: _linkedElderly,
        ),
      ),
    );
  }

  void _openProfile() {
    Navigator.pushNamed(context, '/caregiver-profile');
  }

  void _handleNavigation(int index) {
    if (index == 0) return;
    if (index == 1) {
      if (_linkedElderly.isEmpty) {
        unawaited(_openLinkElderly());
      } else {
        _openStatus(_linkedElderly.first);
      }
      return;
    }
    if (index == 2) {
      if (_linkedElderly.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Link an elderly account before adding reminders.'),
          ),
        );
      } else {
        _openMedication(_linkedElderly.first);
      }
      return;
    }
    _openProfile();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _background,
      appBar: _DashboardAppBar(
        title: 'Caregiver Dashboard',
        onAvatarPressed: _openProfile,
      ),
      bottomNavigationBar: CaregiverBottomNavigation(
        selectedIndex: 0,
        onHome: () {},
        onStatus: () => _handleNavigation(1),
        onMedicine: () => _handleNavigation(2),
        onProfile: _openProfile,
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          color: _orange,
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
            children: [
              Text(
                '${_greeting()}, $_caregiverName',
                style: const TextStyle(
                  color: _ink,
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 5),
              const Text(
                'Monitor linked elderly safety and medicine status.',
                style: TextStyle(color: Colors.black54),
              ),
              const SizedBox(height: 20),
              _SectionHeading(
                title: 'Linked Elderly',
                actionLabel: 'Add',
                onAction: _openLinkElderly,
              ),
              const SizedBox(height: 10),
              FutureBuilder<List<LinkedElderly>>(
                future: _linkedFuture,
                builder: (context, snapshot) {
                  if (_linkedFuture == null ||
                      snapshot.connectionState == ConnectionState.waiting) {
                    return const _LoadingCard();
                  }
                  if (snapshot.hasError) {
                    return const _MessageCard(
                      icon: Icons.cloud_off_rounded,
                      title: 'Unable to load linked accounts',
                      message: 'Pull down to try again.',
                      color: _red,
                    );
                  }
                  final linked = snapshot.data ?? const <LinkedElderly>[];
                  if (linked.isEmpty) {
                    return _MessageCard(
                      icon: Icons.person_add_alt_1_rounded,
                      title: 'No elderly account linked',
                      message:
                          'Use the elderly user\'s private link code or registered email.',
                      color: _orange,
                      actionLabel: 'Link elderly',
                      onAction: _openLinkElderly,
                    );
                  }
                  return Column(
                    children: [
                      for (var index = 0; index < linked.length; index++) ...[
                        _ElderlyCard(
                          elderly: linked[index],
                          refreshVersion: _refreshVersion,
                          onViewStatus: () => _openStatus(linked[index]),
                          onManageMedication: () =>
                              _openMedication(linked[index]),
                        ),
                        if (index != linked.length - 1)
                          const SizedBox(height: 14),
                      ],
                    ],
                  );
                },
              ),
              const SizedBox(height: 22),
              const _SectionHeading(title: 'Emergency Alert'),
              const SizedBox(height: 10),
              _buildEmergencyStatus(),
              const SizedBox(height: 18),
              const _PrivacyNote(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmergencyStatus() {
    final caregiverId = _caregiverId;
    if (caregiverId == null) return const _LoadingCard(compact: true);
    return StreamBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
      stream: _emergencyAlerts,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const _MessageCard(
            icon: Icons.notifications_off_outlined,
            title: 'Alert status unavailable',
            message: 'Pull down to try again.',
            color: _red,
          );
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _LoadingCard(compact: true);
        }
        final active =
            (snapshot.data ??
                    const <QueryDocumentSnapshot<Map<String, dynamic>>>[])
                .where((document) => document.data()['status'] == 'active')
                .toList(growable: false)
              ..sort(
                (a, b) => _timestampMillis(
                  b.data()['createdAt'],
                ).compareTo(_timestampMillis(a.data()['createdAt'])),
              );
        if (active.isEmpty) {
          return const _HorizontalStatusCard(
            icon: Icons.verified_user_outlined,
            title: 'No Active Emergency',
            subtitle: 'No unresolved SOS or fall alerts.',
            badge: 'Normal',
            color: _green,
          );
        }
        final alert = active.first.data();
        final elderlyName = _nonEmptyText(
          alert['elderlyName'],
          'Linked elderly',
        );
        final alertType =
            const ['manual_sos', 'wearable_sos'].contains(alert['type'])
            ? 'SOS'
            : 'fall alert';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _HorizontalStatusCard(
              icon: Icons.sos_rounded,
              title: '$elderlyName needs attention',
              subtitle:
                  'An active $alertType was received. Open their status now.',
              badge: 'Urgent',
              color: _red,
              onTap: () {
                final elderlyId = alert['elderlyId'] as String?;
                LinkedElderly? match;
                for (final elderly in _linkedElderly) {
                  if (elderly.id == elderlyId) match = elderly;
                }
                if (match != null) _openStatus(match);
              },
            ),
            AlertLocationCard(location: alert['location']),
          ],
        );
      },
    );
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }
}

class CaregiverElderlyStatusScreen extends StatefulWidget {
  const CaregiverElderlyStatusScreen({
    super.key,
    required this.elderly,
    this.linkedElderly,
    this.careLinkRepository,
    this.caregiverId,
  });

  final LinkedElderly elderly;
  final List<LinkedElderly>? linkedElderly;
  final CareLinkRepository? careLinkRepository;
  final String? caregiverId;

  @override
  State<CaregiverElderlyStatusScreen> createState() =>
      _CaregiverElderlyStatusScreenState();
}

class _CaregiverElderlyStatusScreenState
    extends State<CaregiverElderlyStatusScreen> {
  late LinkedElderly _selectedElderly;
  late List<LinkedElderly> _linkedElderly;
  late Future<_Overview> _overviewFuture;

  @override
  void initState() {
    super.initState();
    _selectedElderly = widget.elderly;
    _linkedElderly = _withSelected(
      widget.linkedElderly ?? const <LinkedElderly>[],
      widget.elderly,
    );
    _overviewFuture = _loadOverview(_selectedElderly.id);
    if (widget.linkedElderly == null) unawaited(_loadLinkedElderly());
  }

  List<LinkedElderly> _withSelected(
    List<LinkedElderly> people,
    LinkedElderly selected,
  ) {
    final values = <LinkedElderly>[
      selected,
      ...people.where((person) => person.id != selected.id),
    ];
    return values;
  }

  Future<void> _loadLinkedElderly() async {
    try {
      final repository =
          widget.careLinkRepository ?? FirestoreCareLinkRepository();
      final caregiverId =
          widget.caregiverId ?? FirebaseAuth.instance.currentUser?.uid;
      if (caregiverId == null || caregiverId.isEmpty) return;
      final people = await repository.loadLinkedElderly(caregiverId);
      if (!mounted || people.isEmpty) return;
      final selected = people
          .where((person) => person.id == _selectedElderly.id)
          .firstOrNull;
      final active = selected ?? people.first;
      final accountChanged = active.id != _selectedElderly.id;
      setState(() {
        _selectedElderly = active;
        _linkedElderly = _withSelected(people, active);
        if (accountChanged) _overviewFuture = _loadOverview(active.id);
      });
    } catch (_) {
      // The selected account remains usable if the account list cannot refresh.
    }
  }

  void _selectElderly(String id) {
    final selected = _linkedElderly
        .where((person) => person.id == id)
        .firstOrNull;
    if (selected == null || selected.id == _selectedElderly.id) return;
    setState(() {
      _selectedElderly = selected;
      _overviewFuture = _loadOverview(selected.id);
    });
  }

  Future<void> _refresh() async {
    setState(() => _overviewFuture = _loadOverview(_selectedElderly.id));
    await _overviewFuture;
  }

  void _openMedication({bool replace = false}) {
    final route = MaterialPageRoute<void>(
      builder: (_) => CaregiverMedicationScheduleScreen(
        elderly: _selectedElderly,
        linkedElderly: _linkedElderly,
      ),
    );
    if (replace) {
      Navigator.pushReplacement<void, void>(context, route);
    } else {
      Navigator.push<void>(context, route);
    }
  }

  Future<void> _copyEmergencyNumber() async {
    if (_selectedElderly.emergencyPhone.isEmpty) return;
    await Clipboard.setData(
      ClipboardData(text: _selectedElderly.emergencyPhone),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Emergency contact number copied.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _background,
      appBar: const _DashboardAppBar(
        title: 'Elderly Status',
        showAvatar: false,
        showBack: true,
      ),
      bottomNavigationBar: CaregiverBottomNavigation(
        selectedIndex: 1,
        onHome: () => openCaregiverHome(context),
        onStatus: () {},
        onMedicine: () => _openMedication(replace: true),
        onProfile: () => openCaregiverProfile(context),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            child: CaregiverElderlySelector(
              people: [
                for (final person in _linkedElderly)
                  (id: person.id, name: person.fullName),
              ],
              selectedId: _selectedElderly.id,
              onChanged: _selectElderly,
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              color: _orange,
              onRefresh: _refresh,
              child: FutureBuilder<_Overview>(
                future: _overviewFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return ListView(
                      padding: const EdgeInsets.all(20),
                      children: const [_LoadingCard()],
                    );
                  }
                  if (snapshot.hasError) {
                    return ListView(
                      padding: const EdgeInsets.all(20),
                      children: const [
                        _MessageCard(
                          icon: Icons.cloud_off_rounded,
                          title: 'Status could not be loaded',
                          message: 'Pull down to try again.',
                          color: _red,
                        ),
                      ],
                    );
                  }
                  final overview = snapshot.data ?? _Overview.empty;
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
                    children: [
                      Text(
                        'Status, ${_selectedElderly.fullName}',
                        style: const TextStyle(
                          color: _ink,
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 14),
                      _ActiveEmergencyPanel(
                        key: ValueKey('emergency-${_selectedElderly.id}'),
                        elderly: _selectedElderly,
                      ),
                      const SizedBox(height: 20),
                      const _SectionHeading(title: 'Today\'s Activity'),
                      const SizedBox(height: 10),
                      _CaregiverActivityStatusCard(
                        key: ValueKey('activity-${_selectedElderly.id}'),
                        elderlyId: _selectedElderly.id,
                      ),
                      const SizedBox(height: 20),
                      const _SectionHeading(title: 'Device & Sensor'),
                      const SizedBox(height: 10),
                      const _HorizontalStatusCard(
                        icon: Icons.phone_android_rounded,
                        title: 'Elderly phone motion sensors',
                        subtitle:
                            'Processed on the elderly phone. Live connection status is not shared.',
                        badge: 'On device',
                        color: _orange,
                      ),
                      const SizedBox(height: 20),
                      const _SectionHeading(title: 'Fall Detection'),
                      const SizedBox(height: 10),
                      _FallStatusCard(event: overview.latestFall),
                      const SizedBox(height: 20),
                      const _SectionHeading(title: 'Medication Today'),
                      const SizedBox(height: 10),
                      _MedicationCounts(summary: overview.medication),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 48,
                        child: OutlinedButton.icon(
                          onPressed: _openMedication,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _orange,
                            side: const BorderSide(color: _orange),
                          ),
                          icon: const Icon(Icons.medication_rounded),
                          label: const Text('Manage Medication'),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const _SectionHeading(title: 'Emergency Contact'),
                      const SizedBox(height: 10),
                      _EmergencyContactCard(
                        phone: _selectedElderly.emergencyPhone,
                        onCopy: _copyEmergencyNumber,
                      ),
                      const SizedBox(height: 20),
                      _SectionHeading(
                        title: 'Recent Fall Records',
                        actionLabel: '${overview.falls.length} total',
                      ),
                      const SizedBox(height: 10),
                      if (overview.falls.isEmpty)
                        const _MessageCard(
                          icon: Icons.health_and_safety_outlined,
                          title: 'No fall records',
                          message:
                              'Possible falls will appear here after detection.',
                          color: _green,
                        )
                      else
                        _FallHistory(events: overview.falls.take(4).toList()),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActiveEmergencyPanel extends StatefulWidget {
  const _ActiveEmergencyPanel({super.key, required this.elderly});

  final LinkedElderly elderly;

  @override
  State<_ActiveEmergencyPanel> createState() => _ActiveEmergencyPanelState();
}

class _ActiveEmergencyPanelState extends State<_ActiveEmergencyPanel> {
  String? _resolvingId;

  Future<void> _resolve(
    QueryDocumentSnapshot<Map<String, dynamic>> alert,
  ) async {
    final caregiverId = FirebaseAuth.instance.currentUser?.uid;
    if (caregiverId == null || _resolvingId != null) return;
    setState(() => _resolvingId = alert.id);
    try {
      await alert.reference.update(<String, dynamic>{
        'status': 'resolved',
        'resolvedAt': FieldValue.serverTimestamp(),
        'resolvedByCaregiverId': caregiverId,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Emergency marked as resolved.'),
          backgroundColor: _green,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Emergency could not be resolved: $error')),
      );
    } finally {
      if (mounted) setState(() => _resolvingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final caregiverId = FirebaseAuth.instance.currentUser?.uid;
    if (caregiverId == null) return const SizedBox.shrink();
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('emergency_alerts')
          .where('elderlyId', isEqualTo: widget.elderly.id)
          .where('recipientCaregiverIds', arrayContains: caregiverId)
          .orderBy('createdAt', descending: true)
          .limit(30)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const _MessageCard(
            icon: Icons.cloud_off_rounded,
            title: 'Emergency status unavailable',
            message: 'Pull down to try again.',
            color: _red,
          );
        }
        QueryDocumentSnapshot<Map<String, dynamic>>? active;
        for (final document
            in snapshot.data?.docs ??
                const <QueryDocumentSnapshot<Map<String, dynamic>>>[]) {
          final data = document.data();
          if (data['elderlyId'] == widget.elderly.id &&
              data['status'] == 'active') {
            active = document;
            break;
          }
        }
        if (active == null) return const SizedBox.shrink();
        final data = active.data();
        final automatic = !const [
          'manual_sos',
          'wearable_sos',
        ].contains(data['type']);
        return _SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.sos_rounded, color: _red, size: 34),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          automatic ? 'Active fall alert' : 'Active SOS alert',
                          style: const TextStyle(
                            color: _red,
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const Text(
                          'Confirm the elderly user is safe before resolving.',
                          style: TextStyle(color: Colors.black54, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              AlertLocationCard(location: data['location']),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _resolvingId == active.id
                      ? null
                      : () => _resolve(active!),
                  style: FilledButton.styleFrom(backgroundColor: _green),
                  icon: _resolvingId == active.id
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.check_circle_outline_rounded),
                  label: const Text('Mark Resolved'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ElderlyCard extends StatefulWidget {
  const _ElderlyCard({
    required this.elderly,
    required this.refreshVersion,
    required this.onViewStatus,
    required this.onManageMedication,
  });

  final LinkedElderly elderly;
  final int refreshVersion;
  final VoidCallback onViewStatus;
  final VoidCallback onManageMedication;

  @override
  State<_ElderlyCard> createState() => _ElderlyCardState();
}

class _ElderlyCardState extends State<_ElderlyCard> {
  late Future<_Overview> _overviewFuture;

  @override
  void initState() {
    super.initState();
    _overviewFuture = _loadOverview(widget.elderly.id);
  }

  @override
  void didUpdateWidget(covariant _ElderlyCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.elderly.id != widget.elderly.id ||
        oldWidget.refreshVersion != widget.refreshVersion) {
      _overviewFuture = _loadOverview(widget.elderly.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final elderly = widget.elderly;
    return _SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CircleAvatar(
                radius: 29,
                backgroundColor: Color(0xFFFFE1C1),
                child: Icon(Icons.elderly_rounded, color: _orange, size: 33),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      elderly.fullName,
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _demographicText(elderly),
                      style: const TextStyle(color: Colors.black54),
                    ),
                    if (elderly.medicalCondition.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        elderly.medicalCondition.trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF846E60),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const _StatusPill(label: 'Linked', color: _green),
            ],
          ),
          const SizedBox(height: 12),
          _InfoRow(
            icon: Icons.phone_in_talk_outlined,
            text: elderly.emergencyPhone.isEmpty
                ? 'Emergency contact not provided'
                : 'Emergency contact: ${elderly.emergencyPhone}',
          ),
          const SizedBox(height: 5),
          const _InfoRow(
            icon: Icons.smartphone_rounded,
            text: 'Activity detection runs on the elderly phone',
          ),
          const SizedBox(height: 16),
          FutureBuilder<_Overview>(
            future: _overviewFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const LinearProgressIndicator(
                  color: _orange,
                  backgroundColor: Color(0xFFFFE8D5),
                );
              }
              if (snapshot.hasError) {
                return const Text(
                  'Status summary unavailable. Pull down to retry.',
                  style: TextStyle(color: _red, fontSize: 12),
                );
              }
              final overview = snapshot.data ?? _Overview.empty;
              return Row(
                children: [
                  Expanded(
                    child: _CaregiverActivityTile(elderlyId: elderly.id),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _OverviewTile(
                      icon: Icons.medication_outlined,
                      label: 'Medicine',
                      value: overview.medication.total == 0
                          ? 'None today'
                          : '${overview.medication.pending} pending',
                      color: overview.medication.pending > 0 ? _amber : _green,
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: widget.onViewStatus,
                  style: FilledButton.styleFrom(
                    backgroundColor: _orange,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: const Text('View Status'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: widget.onManageMedication,
                  style: FilledButton.styleFrom(
                    backgroundColor: _amber,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: const Text('Manage Medicine'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DashboardAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _DashboardAppBar({
    required this.title,
    this.onAvatarPressed,
    this.showAvatar = true,
    this.showBack = false,
  });

  final String title;
  final VoidCallback? onAvatarPressed;
  final bool showAvatar;
  final bool showBack;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      toolbarHeight: 64,
      backgroundColor: _header,
      centerTitle: true,
      titleSpacing: 0,
      leadingWidth: 64,
      leading: showBack
          ? IconButton(
              tooltip: 'Back',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.arrow_back_rounded),
            )
          : Padding(
              padding: const EdgeInsets.all(10),
              child: Image.asset('assets/images/logo_simple.png'),
            ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.black,
          fontSize: 21,
          fontWeight: FontWeight.w900,
        ),
      ),
      actions: [
        SizedBox(
          width: 64,
          child: showAvatar
              ? IconButton(
                  tooltip: 'Caregiver account',
                  onPressed: onAvatarPressed,
                  icon: const CircleAvatar(
                    backgroundColor: Color(0xFFFFE9D8),
                    child: Icon(
                      Icons.volunteer_activism_rounded,
                      color: _orange,
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, this.actionLabel, this.onAction});

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              color: _ink,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        if (actionLabel != null)
          onAction == null
              ? Text(
                  actionLabel!,
                  style: const TextStyle(
                    color: Colors.black45,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                )
              : TextButton.icon(
                  onPressed: onAction,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: Text(actionLabel!),
                ),
      ],
    );
  }
}

class _SurfaceCard extends StatelessWidget {
  const _SurfaceCard({
    required this.child,
    this.padding = const EdgeInsets.all(17),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D000000),
            blurRadius: 14,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({
    required this.icon,
    required this.title,
    required this.message,
    required this.color,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final Color color;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return _SurfaceCard(
      child: Column(
        children: [
          CircleAvatar(
            radius: 25,
            backgroundColor: color.withValues(alpha: 0.12),
            child: Icon(icon, color: color, size: 29),
          ),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 5),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black54, height: 1.35),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 14),
            FilledButton(
              onPressed: onAction,
              style: FilledButton.styleFrom(backgroundColor: color),
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

class _HorizontalStatusCard extends StatelessWidget {
  const _HorizontalStatusCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.badge,
    required this.color,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String badge;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return _SurfaceCard(
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                radius: 25,
                backgroundColor: color.withValues(alpha: 0.12),
                child: Icon(icon, color: color, size: 28),
              ),
              const SizedBox(width: 13),
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
                      subtitle,
                      style: const TextStyle(
                        color: Colors.black54,
                        fontSize: 12,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _StatusPill(label: badge, color: color),
            ],
          ),
        ),
      ),
    );
  }
}

class _OverviewTile extends StatelessWidget {
  const _OverviewTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 88),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 25),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(color: Colors.black54, fontSize: 11),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CaregiverActivityTile extends StatelessWidget {
  const _CaregiverActivityTile({required this.elderlyId});

  final String elderlyId;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('activity_status')
          .doc(elderlyId)
          .snapshots(),
      builder: (context, snapshot) {
        final activity = _RemoteActivity.fromData(snapshot.data?.data());
        return _OverviewTile(
          icon: activity.active
              ? Icons.directions_walk_rounded
              : Icons.sensors_off_rounded,
          label: 'Activity',
          value: activity.active
              ? _friendlyActivity(activity.label)
              : 'No live data',
          color: activity.active ? _green : Colors.grey,
        );
      },
    );
  }
}

class _CaregiverActivityStatusCard extends StatelessWidget {
  const _CaregiverActivityStatusCard({super.key, required this.elderlyId});

  final String elderlyId;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('activity_status')
          .doc(elderlyId)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const _HorizontalStatusCard(
            icon: Icons.cloud_off_rounded,
            title: 'Activity status unavailable',
            subtitle: 'Pull down to try again.',
            badge: 'Offline',
            color: _red,
          );
        }
        final activity = _RemoteActivity.fromData(snapshot.data?.data());
        if (!activity.active) {
          return const _HorizontalStatusCard(
            icon: Icons.sensors_off_rounded,
            title: 'No recent movement status',
            subtitle: 'Open SHCA on the elderly phone or Wear OS watch.',
            badge: 'Offline',
            color: Colors.grey,
          );
        }
        return _HorizontalStatusCard(
          icon: Icons.directions_walk_rounded,
          title: '${_friendlyActivity(activity.label)} detected',
          subtitle:
              '${activity.source == 'watch' ? 'Watch' : 'Phone'} • ${(activity.confidence * 100).round()}% confidence • summary only',
          badge: 'Live',
          color: _green,
        );
      },
    );
  }
}

class _RemoteActivity {
  const _RemoteActivity({
    this.label = '',
    this.source = '',
    this.confidence = 0,
    this.active = false,
    this.updatedAt,
  });

  final String label;
  final String source;
  final double confidence;
  final bool active;
  final DateTime? updatedAt;

  factory _RemoteActivity.fromData(Map<String, dynamic>? data) {
    final candidates = <_RemoteActivity>[];
    for (final source in const <String>['phone', 'watch']) {
      final raw = data?[source];
      if (raw is! Map) continue;
      final measuredAt = raw['measuredAt'];
      final publishedAt = raw['publishedAt'];
      final updatedAt = measuredAt is Timestamp
          ? measuredAt.toDate()
          : publishedAt is Timestamp
          ? publishedAt.toDate()
          : null;
      candidates.add(
        _RemoteActivity(
          label: (raw['label'] as String?) ?? '',
          source: source,
          confidence: (raw['confidence'] as num?)?.toDouble() ?? 0,
          active: raw['active'] == true && raw['label'] != 'Fall detection off',
          updatedAt: updatedAt,
        ),
      );
    }
    candidates.sort(
      (first, second) => (second.updatedAt?.millisecondsSinceEpoch ?? 0)
          .compareTo(first.updatedAt?.millisecondsSinceEpoch ?? 0),
    );
    if (candidates.isEmpty) return const _RemoteActivity();
    final now = DateTime.now();
    final live = candidates
        .where(
          (candidate) =>
              candidate.active &&
              candidate.label.isNotEmpty &&
              candidate.updatedAt != null &&
              now.difference(candidate.updatedAt!).abs() <
                  const Duration(seconds: 90),
        )
        .toList(growable: false);
    final latest = live.isEmpty ? candidates.first : live.first;
    final timestamp = latest.updatedAt;
    final recent =
        timestamp != null &&
        now.difference(timestamp).abs() < const Duration(seconds: 90);
    return _RemoteActivity(
      label: latest.label,
      source: latest.source,
      confidence: latest.confidence,
      active: latest.active && recent && latest.label.isNotEmpty,
      updatedAt: latest.updatedAt,
    );
  }
}

String _friendlyActivity(String label) => switch (label.trim().toLowerCase()) {
  'walking' => 'Walking',
  'running' => 'Running',
  'sitting' => 'Sitting',
  'resting' || 'lying' => 'Resting',
  'fall' || 'possible fall' => 'Possible fall',
  'activity_unknown' => 'Movement unclear',
  final value when value.isNotEmpty =>
    '${value[0].toUpperCase()}${value.substring(1)}',
  _ => 'No live data',
};

class _MedicationCounts extends StatelessWidget {
  const _MedicationCounts({required this.summary});

  final _MedicationSummary summary;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _CountCard(
            label: 'Taken',
            value: summary.taken,
            color: _green,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _CountCard(
            label: 'Pending',
            value: summary.pending,
            color: _amber,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _CountCard(
            label: 'Missed',
            value: summary.missed,
            color: _red,
          ),
        ),
      ],
    );
  }
}

class _CountCard extends StatelessWidget {
  const _CountCard({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return _SurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
      child: Column(
        children: [
          Text(label, style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 6),
          Text(
            '$value',
            style: TextStyle(
              color: color,
              fontSize: 23,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _FallStatusCard extends StatelessWidget {
  const _FallStatusCard({required this.event});

  final _FallEvent? event;

  @override
  Widget build(BuildContext context) {
    final latest = event;
    if (latest == null) {
      return const _HorizontalStatusCard(
        icon: Icons.health_and_safety_outlined,
        title: 'No fall records',
        subtitle: 'No possible fall has been recorded for this account.',
        badge: 'Normal',
        color: _green,
      );
    }
    final cancelled = latest.status == 'cancelled';
    final alertSent = latest.status == 'alert_sent';
    return _HorizontalStatusCard(
      icon: cancelled ? Icons.check_rounded : Icons.warning_amber_rounded,
      title: cancelled
          ? 'Latest possible fall: user safe'
          : alertSent
          ? 'Fall alert sent'
          : 'Fall confirmation pending',
      subtitle: '${_formatDateTime(latest.detectedAt)} • ${latest.activity}',
      badge: cancelled
          ? 'Cancelled'
          : alertSent
          ? 'Alert sent'
          : 'Check now',
      color: cancelled
          ? _green
          : alertSent
          ? _red
          : _amber,
    );
  }
}

class _FallHistory extends StatelessWidget {
  const _FallHistory({required this.events});

  final List<_FallEvent> events;

  @override
  Widget build(BuildContext context) {
    return _SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var index = 0; index < events.length; index++) ...[
            _FallHistoryRow(event: events[index]),
            if (index != events.length - 1) const Divider(height: 1),
          ],
        ],
      ),
    );
  }
}

class _FallHistoryRow extends StatelessWidget {
  const _FallHistoryRow({required this.event});

  final _FallEvent event;

  @override
  Widget build(BuildContext context) {
    final cancelled = event.status == 'cancelled';
    final color = cancelled ? _green : _red;
    return Padding(
      padding: const EdgeInsets.all(15),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: color.withValues(alpha: 0.11),
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
                  cancelled ? 'Possible fall — user safe' : 'Fall alert sent',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 3),
                Text(
                  '${_formatDateTime(event.detectedAt)} • ${event.activity}',
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
              ],
            ),
          ),
          _StatusPill(label: cancelled ? 'Cancelled' : 'Sent', color: color),
        ],
      ),
    );
  }
}

class _EmergencyContactCard extends StatelessWidget {
  const _EmergencyContactCard({required this.phone, required this.onCopy});

  final String phone;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return _SurfaceCard(
      child: Row(
        children: [
          const CircleAvatar(
            backgroundColor: Color(0xFFFFE4CD),
            child: Icon(Icons.phone_in_talk_rounded, color: _orange),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Saved emergency number',
                  style: TextStyle(color: Colors.black54, fontSize: 12),
                ),
                const SizedBox(height: 3),
                SelectableText(
                  phone.isEmpty ? 'Not provided' : phone,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
          if (phone.isNotEmpty)
            IconButton(
              tooltip: 'Copy emergency contact number',
              onPressed: onCopy,
              icon: const Icon(Icons.copy_rounded),
            ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 17, color: Colors.black45),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: Colors.black54, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return _SurfaceCard(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: compact ? 4 : 20),
        child: const Center(child: CircularProgressIndicator(color: _orange)),
      ),
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF0E3),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.privacy_tip_outlined, color: _orange, size: 21),
          SizedBox(width: 9),
          Expanded(
            child: Text(
              'Motion is analysed privately on the elderly device using the accelerometer and gyroscope.',
              style: TextStyle(color: Color(0xFF725D50), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _Overview {
  const _Overview({required this.medication, required this.falls});

  static const empty = _Overview(
    medication: _MedicationSummary.empty,
    falls: <_FallEvent>[],
  );

  final _MedicationSummary medication;
  final List<_FallEvent> falls;

  _FallEvent? get latestFall => falls.isEmpty ? null : falls.first;
}

class _MedicationSummary {
  const _MedicationSummary({
    required this.taken,
    required this.pending,
    required this.missed,
  });

  static const empty = _MedicationSummary(taken: 0, pending: 0, missed: 0);

  final int taken;
  final int pending;
  final int missed;

  int get total => taken + pending + missed;
}

class _FallEvent {
  const _FallEvent({
    required this.status,
    required this.activity,
    required this.detectedAt,
  });

  final String status;
  final String activity;
  final DateTime? detectedAt;

  factory _FallEvent.fromFirestore(Map<String, dynamic> data) {
    return _FallEvent(
      status: _nonEmptyText(data['status'], 'pending_confirmation'),
      activity: _nonEmptyText(data['activity'], 'Unknown activity'),
      detectedAt: (data['detectedAt'] as Timestamp?)?.toDate(),
    );
  }
}

Future<_Overview> _loadOverview(String elderlyId) async {
  final medicationRepository = FirestoreMedicationRepository();
  final results = await Future.wait<Object>([
    medicationRepository.loadSchedules(elderlyId),
    medicationRepository.loadRecords(elderlyId),
    FirebaseFirestore.instance
        .collection('fall_events')
        .where('elderlyId', isEqualTo: elderlyId)
        .orderBy('detectedAt', descending: true)
        .limit(100)
        .get(),
  ]);
  final schedules = results[0] as List<MedicationSchedule>;
  final records = results[1] as List<MedicationRecord>;
  final fallSnapshot = results[2] as QuerySnapshot<Map<String, dynamic>>;
  final falls =
      fallSnapshot.docs
          .map((document) => _FallEvent.fromFirestore(document.data()))
          .toList(growable: false)
        ..sort(
          (a, b) => (b.detectedAt?.millisecondsSinceEpoch ?? 0).compareTo(
            a.detectedAt?.millisecondsSinceEpoch ?? 0,
          ),
        );
  return _Overview(
    medication: _summaryForToday(schedules, records),
    falls: falls,
  );
}

_MedicationSummary _summaryForToday(
  List<MedicationSchedule> schedules,
  List<MedicationRecord> records,
) {
  final today = MedicationController.dateOnly(DateTime.now());
  var taken = 0;
  var pending = 0;
  var missed = 0;
  for (final schedule in schedules) {
    if (!schedule.isScheduledOn(today)) continue;
    for (final occurrence in MedicationController.scheduledOccurrences(
      schedule,
      today,
    )) {
      final key = MedicationController.recordKeyFor(schedule, occurrence);
      MedicationRecord? record;
      for (final candidate in records) {
        if (candidate.key == key) {
          record = candidate;
          break;
        }
      }
      switch (record?.status ?? MedicationStatus.pending) {
        case MedicationStatus.taken:
          taken++;
          break;
        case MedicationStatus.missed:
          missed++;
          break;
        case MedicationStatus.pending:
        case MedicationStatus.snoozed:
          pending++;
          break;
      }
    }
  }
  return _MedicationSummary(taken: taken, pending: pending, missed: missed);
}

String _demographicText(LinkedElderly elderly) {
  final parts = <String>[];
  if (elderly.age != null) parts.add('${elderly.age} years old');
  if (elderly.gender.trim().isNotEmpty) parts.add(elderly.gender.trim());
  if (elderly.relationship.trim().isNotEmpty) {
    parts.add(elderly.relationship.trim());
  }
  return parts.isEmpty ? 'Linked elderly account' : parts.join(' • ');
}

String _nonEmptyText(dynamic value, String fallback) {
  final text = value is String ? value.trim() : '';
  return text.isEmpty ? fallback : text;
}

int _timestampMillis(dynamic value) {
  if (value is Timestamp) return value.millisecondsSinceEpoch;
  return 0;
}

String _formatDateTime(DateTime? value) {
  if (value == null) return 'Time pending';
  final hour = value.hour == 0
      ? 12
      : value.hour > 12
      ? value.hour - 12
      : value.hour;
  final minute = value.minute.toString().padLeft(2, '0');
  final period = value.hour >= 12 ? 'PM' : 'AM';
  return '${value.day}/${value.month}/${value.year} • $hour:$minute $period';
}
