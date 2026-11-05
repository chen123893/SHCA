import 'package:shca/widgets/alert_location_card.dart';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shca/screens/auth/caregiver_medication_schedule.dart';
import 'package:shca/screens/auth/link_elderly.dart';
import 'package:shca/services/care_link_service.dart';
import 'package:shca/services/caregiver_alert_service.dart';
import 'package:shca/services/profile_service.dart';
import 'package:shca/services/push_notification_service.dart';
import 'package:shca/services/session_service.dart';

class CaregiverHomeScreen extends StatefulWidget {
  const CaregiverHomeScreen({super.key, this.repository});

  final CareLinkRepository? repository;

  @override
  State<CaregiverHomeScreen> createState() => _CaregiverHomeScreenState();
}

class _CaregiverHomeScreenState extends State<CaregiverHomeScreen> {
  static const Color _background = Color(0xFFFFF8F0);
  static const Color _orange = Color(0xFFFF8128);
  static const Color _ink = Color(0xFF241D19);
  static const Color _green = Color(0xFF4F9A4B);

  late final CareLinkRepository _repository;
  Future<List<LinkedElderly>>? _linkedFuture;
  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>>? _emergencyAlerts;
  String _caregiverName = 'Caregiver';
  String? _caregiverId;
  bool _signingOut = false;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? FirestoreCareLinkRepository();
    unawaited(_load());
  }

  Future<void> _load() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final results = await Future.wait<Object?>(<Future<Object?>>[
      FirebaseFirestore.instance.collection('users').doc(user.uid).get(),
      FirestoreProfileRepository().loadCaregiverProfile(user.uid),
    ]);
    final profile = results[0] as DocumentSnapshot<Map<String, dynamic>>;
    final caregiverProfile = results[1] as CaregiverProfile?;
    final name = (profile.data()?['fullName'] as String?)?.trim();
    if (caregiverProfile?.pushAlert ?? true) {
      unawaited(PushNotificationService.instance.registerCaregiver(user.uid));
    } else {
      unawaited(PushNotificationService.instance.unregisterCaregiver());
    }
    if (!mounted) return;
    setState(() {
      _caregiverId = user.uid;
      if (name != null && name.isNotEmpty) _caregiverName = name;
      _setLinkedFuture(user.uid, _repository.loadLinkedElderly(user.uid));
    });
  }

  void _setLinkedFuture(
    String caregiverId,
    Future<List<LinkedElderly>> linked,
  ) {
    _linkedFuture = linked;
    _emergencyAlerts = watchCaregiverEmergencyAlerts(
      caregiverId: caregiverId,
      elderlyIds: linked.then((people) => people.map((person) => person.id)),
      limitPerElderly: 20,
    );
  }

  Future<void> _refresh() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    setState(() => _setLinkedFuture(uid, _repository.loadLinkedElderly(uid)));
    await _linkedFuture;
  }

  Future<void> _signOut() async {
    if (_signingOut) return;
    setState(() => _signingOut = true);
    try {
      await AppSessionService().signOut(caregiver: true);
      if (!mounted) return;
      Navigator.of(
        context,
        rootNavigator: true,
      ).pushNamedAndRemoveUntil('/login', (_) => false);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not log out. Please try again.')),
      );
    } finally {
      if (mounted) setState(() => _signingOut = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _background,
      appBar: AppBar(
        backgroundColor: const Color(0xFFFFB87D),
        title: const Text(
          'Caregiver Dashboard',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            onPressed: _signingOut ? null : _signOut,
            icon: _signingOut
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.logout_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 30),
            children: [
              Text(
                '${_greeting()}, $_caregiverName',
                style: const TextStyle(
                  color: _ink,
                  fontSize: 25,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 5),
              const Text(
                'Linked elderly safety and emergency information',
                style: TextStyle(color: Colors.black54),
              ),
              const SizedBox(height: 16),
              _buildEmergencyStatus(),
              const SizedBox(height: 20),
              FutureBuilder<List<LinkedElderly>>(
                future: _linkedFuture,
                builder: (context, snapshot) {
                  if (_linkedFuture == null ||
                      snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(36),
                        child: CircularProgressIndicator(color: _orange),
                      ),
                    );
                  }
                  if (snapshot.hasError) {
                    return _StatusCard(
                      icon: Icons.cloud_off_rounded,
                      title: 'Unable to load linked accounts',
                      message: 'Pull down to try again.',
                      color: Colors.redAccent,
                    );
                  }
                  final linked = snapshot.data ?? const <LinkedElderly>[];
                  if (linked.isEmpty) return _buildEmptyState();
                  return Column(
                    children: linked
                        .map(
                          (elderly) => Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: _buildElderlyCard(elderly),
                          ),
                        )
                        .toList(growable: false),
                  );
                },
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 52,
                child: FilledButton.icon(
                  onPressed: () async {
                    await Navigator.push<void>(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const LinkElderlyScreen(),
                      ),
                    );
                    if (mounted) await _refresh();
                  },
                  style: FilledButton.styleFrom(backgroundColor: _orange),
                  icon: const Icon(Icons.add_link_rounded),
                  label: const Text('Link Another Elderly Account'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Padding(
      padding: EdgeInsets.only(bottom: 14),
      child: _StatusCard(
        icon: Icons.person_add_alt_1_rounded,
        title: 'No elderly account linked',
        message:
            'Use the elderly user’s private link code or registered email.',
        color: _orange,
      ),
    );
  }

  Widget _buildEmergencyStatus() {
    final caregiverId = _caregiverId;
    if (caregiverId == null) return const SizedBox.shrink();
    return StreamBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
      stream: _emergencyAlerts,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const _StatusCard(
            icon: Icons.notifications_off_outlined,
            title: 'Alert status unavailable',
            message: 'Pull down to try again.',
            color: Colors.redAccent,
          );
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: _orange));
        }
        final active =
            (snapshot.data ??
                    const <QueryDocumentSnapshot<Map<String, dynamic>>>[])
                .where((document) => document.data()['status'] == 'active')
                .toList(growable: false)
              ..sort((a, b) {
                final aTime = a.data()['createdAt'] as Timestamp?;
                final bTime = b.data()['createdAt'] as Timestamp?;
                return (bTime?.millisecondsSinceEpoch ?? 0).compareTo(
                  aTime?.millisecondsSinceEpoch ?? 0,
                );
              });
        if (active.isEmpty) {
          return const _StatusCard(
            icon: Icons.verified_user_outlined,
            title: 'No active emergency',
            message: 'Linked elderly SOS alerts will appear here in real time.',
            color: _green,
          );
        }

        final alert = active.first.data();
        final elderlyName =
            (alert['elderlyName'] as String?)?.trim().isNotEmpty == true
            ? alert['elderlyName'] as String
            : 'Linked elderly user';
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: const Color(0xFFFFE7E4),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE93832)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CircleAvatar(
                backgroundColor: Color(0xFFE93832),
                child: Icon(Icons.sos_rounded, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Emergency alert',
                      style: TextStyle(
                        color: Color(0xFFB5201A),
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$elderlyName requested help. Contact them or use the saved emergency number below.',
                      style: const TextStyle(height: 1.35),
                    ),
                    AlertLocationCard(location: alert['location']),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildElderlyCard(LinkedElderly elderly) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE8DED6)),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x10000000),
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              const CircleAvatar(
                radius: 28,
                backgroundColor: Color(0xFFFFE0B8),
                child: Icon(Icons.elderly_rounded, color: _orange, size: 32),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      elderly.fullName,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      elderly.relationship.isEmpty
                          ? 'Linked elderly'
                          : elderly.relationship,
                      style: const TextStyle(
                        color: _green,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFE6F6EC),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  'Linked',
                  style: TextStyle(
                    color: _green,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const Divider(height: 30),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.phone_in_talk_outlined, color: _orange),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Emergency contact number',
                      style: TextStyle(color: Colors.black54, fontSize: 12),
                    ),
                    const SizedBox(height: 2),
                    SelectableText(
                      elderly.emergencyPhone.isEmpty
                          ? 'Not provided'
                          : elderly.emergencyPhone,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              if (elderly.emergencyPhone.isNotEmpty)
                IconButton(
                  tooltip: 'Copy emergency contact number',
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: elderly.emergencyPhone),
                    );
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Emergency contact number copied.'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.email_outlined, color: Colors.black45),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  elderly.email,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.black54),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      CaregiverMedicationScheduleScreen(elderly: elderly),
                ),
              ),
              style: FilledButton.styleFrom(backgroundColor: _orange),
              icon: const Icon(Icons.medication_rounded),
              label: const Text('Manage Medication'),
            ),
          ),
        ],
      ),
    );
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.icon,
    required this.title,
    required this.message,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE8DED6)),
      ),
      child: Column(
        children: [
          Icon(icon, size: 44, color: color),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 5),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black54, height: 1.4),
          ),
        ],
      ),
    );
  }
}
