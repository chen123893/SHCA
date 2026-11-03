import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shca/screens/auth/change_password.dart';
import 'package:shca/screens/auth/caregiver_dashboard.dart';
import 'package:shca/screens/auth/caregiver_medication_schedule.dart';
import 'package:shca/screens/auth/caregiver_shared.dart';
import 'package:shca/screens/auth/link_elderly.dart';
import 'package:shca/services/care_link_service.dart';
import 'package:shca/services/profile_service.dart';
import 'package:shca/services/push_notification_service.dart';
import 'package:shca/services/session_service.dart';

class CaregiverProfileScreen extends StatefulWidget {
  const CaregiverProfileScreen({
    super.key,
    this.profileRepository,
    this.careLinkRepository,
    this.sessionService,
  });

  final ProfileRepository? profileRepository;
  final CareLinkRepository? careLinkRepository;
  final AppSessionService? sessionService;

  @override
  State<CaregiverProfileScreen> createState() => _CaregiverProfileScreenState();
}

class _CaregiverProfileScreenState extends State<CaregiverProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();

  late final ProfileRepository _profileRepository;
  late final CareLinkRepository _careLinkRepository;
  late final AppSessionService _sessionService;

  String _email = '';
  bool _pushAlert = true;
  bool _smsAlert = false;
  bool _medicationEmailAlert = true;
  bool _loading = true;
  bool _saving = false;
  bool _editing = false;
  bool _signingOut = false;
  String? _error;
  List<LinkedElderly> _linkedElderly = const <LinkedElderly>[];

  @override
  void initState() {
    super.initState();
    _profileRepository =
        widget.profileRepository ?? FirestoreProfileRepository();
    _careLinkRepository =
        widget.careLinkRepository ?? FirestoreCareLinkRepository();
    _sessionService = widget.sessionService ?? AppSessionService();
    unawaited(_load());
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw StateError('Please sign in again.');
      final results = await Future.wait<Object?>(<Future<Object?>>[
        FirebaseFirestore.instance.collection('users').doc(user.uid).get(),
        _profileRepository.loadCaregiverProfile(user.uid),
        _careLinkRepository.loadLinkedElderly(user.uid),
        FirebaseFirestore.instance
            .collection('caregiver_sms_contacts')
            .doc(user.uid)
            .get(),
      ]);
      final userDocument = results[0] as DocumentSnapshot<Map<String, dynamic>>;
      final profile = results[1] as CaregiverProfile?;
      final linked = results[2] as List<LinkedElderly>;
      final data = userDocument.data() ?? const <String, dynamic>{};
      final fullName = (data['fullName'] as String?)?.trim();
      final email = (data['email'] as String?)?.trim();
      if (!mounted) return;
      setState(() {
        _nameController.text = fullName?.isNotEmpty == true
            ? fullName!
            : 'Caregiver';
        _email = email?.isNotEmpty == true ? email! : (user.email ?? '');
        _phoneController.text = (data['phone'] as String?)?.trim() ?? '';
        _pushAlert = profile?.pushAlert ?? true;
        _smsAlert = (results[3] as DocumentSnapshot).exists;
        _medicationEmailAlert = profile?.medicationEmailAlert ?? true;
        _linkedElderly = linked;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    setState(() => _saving = true);
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .update(<String, dynamic>{
            'fullName': _nameController.text.trim(),
            'phone': _phoneController.text.trim(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
      final smsContact = FirebaseFirestore.instance
          .collection('caregiver_sms_contacts')
          .doc(user.uid);
      if (_smsAlert) {
        await smsContact.set({'phone': _smsNumber(_phoneController.text)});
      } else {
        await smsContact.delete();
      }
      await _profileRepository.saveCaregiverProfile(
        CaregiverProfile(
          userId: user.uid,
          pushAlert: _pushAlert,
          smsAlert: _smsAlert,
          medicationEmailAlert: _medicationEmailAlert,
        ),
      );
      // Also copies the email preference onto existing care links so the
      // server can deliver reminders without exposing private user records.
      await _careLinkRepository.loadLinkedElderly(user.uid);
      if (_pushAlert) {
        await PushNotificationService.instance.registerCaregiver(user.uid);
      } else {
        await PushNotificationService.instance.unregisterCaregiver();
      }
      if (!mounted) return;
      setState(() => _editing = false);
      _showMessage('Profile updated successfully.');
    } catch (error) {
      _showMessage(
        'Profile could not be saved. Please try again.',
        error: true,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openLinkElderly() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(builder: (_) => const LinkElderlyScreen()),
    );
    if (mounted) await _load();
  }

  Future<void> _removeLink(LinkedElderly elderly) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.link_off_rounded, color: caregiverRed, size: 38),
        title: const Text('Remove linked elderly?'),
        content: Text(
          'You will stop seeing ${elderly.fullName}\'s fall and medication '
          'information. Their account and records will not be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: caregiverRed),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final caregiverId = FirebaseAuth.instance.currentUser?.uid;
    if (caregiverId == null) return;
    try {
      await _careLinkRepository.unlinkElderly(
        caregiverId: caregiverId,
        elderlyId: elderly.id,
      );
      if (!mounted) return;
      setState(
        () => _linkedElderly = _linkedElderly
            .where((item) => item.id != elderly.id)
            .toList(growable: false),
      );
      _showMessage('${elderly.fullName} was unlinked.');
    } catch (error) {
      _showMessage('The elderly account could not be unlinked.', error: true);
    }
  }

  Future<void> _signOut() async {
    if (_signingOut) return;
    setState(() => _signingOut = true);
    try {
      await _sessionService.signOut(caregiver: true);
      if (!mounted) return;
      Navigator.of(
        context,
        rootNavigator: true,
      ).pushNamedAndRemoveUntil('/login', (_) => false);
    } catch (_) {
      _showMessage(
        'Could not log out. Check your connection and try again.',
        error: true,
      );
    } finally {
      if (mounted) setState(() => _signingOut = false);
    }
  }

  Future<void> _openChangePassword() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute<bool>(
        builder: (_) => const ChangePasswordScreen(
          roleLabel: 'Caregiver',
          accentColor: caregiverOrange,
          backgroundColor: caregiverPageBackground,
        ),
      ),
    );
    if (changed == true && mounted) {
      _showMessage('Password changed successfully.');
    }
  }

  void _openStatus() {
    if (_linkedElderly.isEmpty) {
      unawaited(_openLinkElderly());
      return;
    }
    Navigator.pushReplacement<void, void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => CaregiverElderlyStatusScreen(
          elderly: _linkedElderly.first,
          linkedElderly: _linkedElderly,
        ),
      ),
    );
  }

  void _openMedication() {
    if (_linkedElderly.isEmpty) {
      _showMessage('Link an elderly account before managing medication.');
      return;
    }
    Navigator.pushReplacement<void, void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => CaregiverMedicationScheduleScreen(
          elderly: _linkedElderly.first,
          linkedElderly: _linkedElderly,
        ),
      ),
    );
  }

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? caregiverRed : caregiverGreen,
      ),
    );
  }

  String? _validateName(String? value) =>
      value == null || value.trim().isEmpty ? 'Enter your full name.' : null;

  String? _smsNumber(String value) {
    final compact = value.trim().replaceAll(RegExp(r'[ ()-]'), '');
    final number = compact.startsWith('0')
        ? '+60${compact.substring(1)}'
        : compact.startsWith('60')
        ? '+$compact'
        : compact;
    return RegExp(r'^[+][1-9][0-9]{8,14}$').hasMatch(number) ? number : null;
  }

  String? _validatePhone(String? value) {
    if (_smsAlert && _smsNumber(value ?? '') == null) {
      return 'For SMS, enter a Malaysian mobile number or include the country code.';
    }
    final digits = (value ?? '').replaceAll(RegExp(r'\D'), '');
    if (digits.length < 9 || digits.length > 15) {
      return 'Enter a valid phone number.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: caregiverPageBackground,
      appBar: const CaregiverPageHeader(title: 'Profile'),
      bottomNavigationBar: CaregiverBottomNavigation(
        selectedIndex: 3,
        onHome: () => openCaregiverHome(context),
        onStatus: _openStatus,
        onMedicine: _openMedication,
        onProfile: () {},
      ),
      body: SafeArea(top: false, child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: caregiverOrange),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.cloud_off_rounded,
                color: caregiverRed,
                size: 54,
              ),
              const SizedBox(height: 12),
              const Text(
                'Profile could not be loaded',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('Try Again')),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      color: caregiverOrange,
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
        children: [
          const Center(child: _CaregiverAvatar()),
          const SizedBox(height: 12),
          Text(
            _nameController.text,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
          ),
          const Text(
            'Caregiver account',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 22),
          if (_editing) _buildEditForm() else _buildProfileDetails(),
          const SizedBox(height: 18),
          if (!_editing)
            Column(
              children: [
                OutlinedButton.icon(
                  key: const Key('caregiver-change-password'),
                  onPressed: _openChangePassword,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: caregiverOrange,
                    minimumSize: const Size(double.infinity, 52),
                    side: const BorderSide(color: caregiverOrange),
                  ),
                  icon: const Icon(Icons.lock_reset_rounded),
                  label: const Text('Change Password'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        key: const Key('edit-caregiver-profile'),
                        onPressed: () => setState(() => _editing = true),
                        style: FilledButton.styleFrom(
                          backgroundColor: caregiverOrange,
                          minimumSize: const Size(0, 52),
                        ),
                        icon: const Icon(Icons.edit_rounded),
                        label: const Text('Edit Profile'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        key: const Key('caregiver-logout'),
                        onPressed: _signingOut ? null : _signOut,
                        style: FilledButton.styleFrom(
                          backgroundColor: caregiverRed,
                          minimumSize: const Size(0, 52),
                        ),
                        icon: _signingOut
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.logout_rounded),
                        label: Text(_signingOut ? 'Logging out…' : 'Logout'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildProfileDetails() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(title: 'Caregiver Information'),
        const SizedBox(height: 8),
        _ProfileCard(
          children: [
            _InformationRow(
              icon: Icons.person_outline_rounded,
              label: 'Full name',
              value: _nameController.text,
            ),
            _InformationRow(
              icon: Icons.email_outlined,
              label: 'Email',
              value: _email,
            ),
            _InformationRow(
              icon: Icons.phone_outlined,
              label: 'Phone number',
              value: _phoneController.text.isEmpty
                  ? 'Not provided'
                  : _phoneController.text,
            ),
          ],
        ),
        const SizedBox(height: 19),
        Row(
          children: [
            const Expanded(child: _SectionTitle(title: 'Linked Elderly')),
            FilledButton.icon(
              key: const Key('profile-link-elderly'),
              onPressed: _openLinkElderly,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2F762D),
                padding: const EdgeInsets.symmetric(horizontal: 13),
              ),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_linkedElderly.isEmpty)
          _ProfileCard(
            children: const [
              _InformationRow(
                icon: Icons.person_add_alt_1_rounded,
                label: 'No account linked',
                value: 'Tap Add to connect an elderly account.',
              ),
            ],
          )
        else
          for (final elderly in _linkedElderly) ...[
            _LinkedElderlyCard(
              elderly: elderly,
              onRemove: () => _removeLink(elderly),
            ),
            const SizedBox(height: 10),
          ],
        const SizedBox(height: 9),
        const _SectionTitle(title: 'Notification Settings'),
        const SizedBox(height: 8),
        _ProfileCard(
          children: [
            _NotificationRow(
              icon: Icons.notifications_active_outlined,
              title: 'Push notifications',
              subtitle: _pushAlert
                  ? 'Fall and SOS alerts are enabled'
                  : 'Alerts are disabled',
              enabled: _pushAlert,
            ),
            _NotificationRow(
              icon: Icons.sms_outlined,
              title: 'Fall and SOS SMS',
              subtitle: _smsAlert
                  ? 'Receive fall and SOS texts from linked elderly phones.'
                  : 'Fall and SOS texts are off.',
              enabled: _smsAlert,
            ),
            _NotificationRow(
              icon: Icons.email_outlined,
              title: 'Medication reminder email',
              subtitle: _medicationEmailAlert
                  ? 'Sent when a linked elderly medicine is due'
                  : 'Email reminders are disabled',
              enabled: _medicationEmailAlert,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildEditForm() {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle(title: 'Update Profile'),
          const SizedBox(height: 8),
          _ProfileCard(
            children: [
              TextFormField(
                key: const Key('caregiver-profile-name'),
                controller: _nameController,
                validator: _validateName,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Full name',
                  prefixIcon: Icon(Icons.person_outline_rounded),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 13),
              TextFormField(
                initialValue: _email,
                readOnly: true,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.email_outlined),
                  helperText: 'Your sign-in email cannot be changed here.',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 13),
              TextFormField(
                key: const Key('caregiver-profile-phone'),
                controller: _phoneController,
                validator: _validatePhone,
                keyboardType: TextInputType.phone,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9+()\-\s]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Phone number',
                  prefixIcon: Icon(Icons.phone_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const _SectionTitle(title: 'Notification Settings'),
          const SizedBox(height: 8),
          _ProfileCard(
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _pushAlert,
                activeThumbColor: caregiverGreen,
                title: const Text(
                  'Push notifications',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: const Text('Receive free FCM fall and SOS alerts.'),
                onChanged: (value) => setState(() => _pushAlert = value),
              ),
              const Divider(),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _smsAlert,
                activeThumbColor: caregiverGreen,
                title: const Text(
                  'Fall and SOS SMS',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: const Text(
                  'Share your phone number with linked elderly accounts so their phones can text you after a fall or SOS.',
                ),
                onChanged: (value) => setState(() => _smsAlert = value),
              ),
              const Divider(),
              SwitchListTile(
                key: const Key('caregiver-medication-email-alert'),
                contentPadding: EdgeInsets.zero,
                value: _medicationEmailAlert,
                activeThumbColor: caregiverGreen,
                title: const Text(
                  'Missed-dose email',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: Text(
                  _email.isEmpty
                      ? 'Add a sign-in email to receive missed-dose alerts.'
                      : 'Email $_email only when a dose is missed.',
                ),
                onChanged: _email.isEmpty
                    ? null
                    : (value) => setState(() => _medicationEmailAlert = value),
              ),
            ],
          ),
          const SizedBox(height: 17),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _saving
                      ? null
                      : () {
                          setState(() => _editing = false);
                          unawaited(_load());
                        },
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 52),
                  ),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  key: const Key('save-caregiver-profile'),
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: caregiverOrange,
                    minimumSize: const Size(0, 52),
                  ),
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(_saving ? 'Saving...' : 'Save Changes'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CaregiverAvatar extends StatelessWidget {
  const _CaregiverAvatar();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 112,
      height: 112,
      decoration: BoxDecoration(
        color: const Color(0xFFFFE7D3),
        shape: BoxShape.circle,
        border: Border.all(color: caregiverOrange, width: 3),
      ),
      child: const Icon(
        Icons.volunteer_activism_rounded,
        color: caregiverOrange,
        size: 65,
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        color: caregiverInk,
        fontSize: 18,
        fontWeight: FontWeight.w900,
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: caregiverBorder),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x0D000000),
            blurRadius: 13,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: Column(children: children),
    );
  }
}

class _InformationRow extends StatelessWidget {
  const _InformationRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: caregiverOrange, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    color: caregiverInk,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LinkedElderlyCard extends StatelessWidget {
  const _LinkedElderlyCard({required this.elderly, required this.onRemove});

  final LinkedElderly elderly;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final details = <String>[
      if (elderly.age != null) '${elderly.age} years old',
      if (elderly.gender.trim().isNotEmpty) elderly.gender,
      if (elderly.relationship.trim().isNotEmpty) elderly.relationship,
    ].join(' • ');
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: caregiverBorder),
      ),
      child: Row(
        children: [
          const CircleAvatar(
            radius: 27,
            backgroundColor: Color(0xFFFFE2B5),
            child: Icon(
              Icons.elderly_rounded,
              color: caregiverOrange,
              size: 31,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  elderly.fullName,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if (details.isNotEmpty)
                  Text(
                    details,
                    style: const TextStyle(color: Colors.black54, fontSize: 12),
                  ),
              ],
            ),
          ),
          FilledButton(
            key: Key('unlink-${elderly.id}'),
            onPressed: onRemove,
            style: FilledButton.styleFrom(
              backgroundColor: caregiverRed,
              padding: const EdgeInsets.symmetric(horizontal: 13),
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }
}

class _NotificationRow extends StatelessWidget {
  const _NotificationRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Icon(icon, color: enabled ? caregiverGreen : Colors.black38),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: enabled
                  ? const Color(0xFFE8F7EE)
                  : const Color(0xFFF0EEEC),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              enabled ? 'Enabled' : 'Off',
              style: TextStyle(
                color: enabled ? caregiverGreen : Colors.black45,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
