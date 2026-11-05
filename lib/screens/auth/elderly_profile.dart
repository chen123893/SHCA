import 'package:shca/widgets/emergency_location_settings.dart';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shca/screens/auth/change_password.dart';
import 'package:shca/screens/auth/connect_watch.dart';
import 'package:shca/screens/auth/elderly_monitoring.dart';
import 'package:shca/screens/auth/elderly_shared.dart';
import 'package:shca/services/activity_recognition_service.dart';
import 'package:shca/services/phone_fall_monitor.dart';
import 'package:shca/services/care_link_service.dart';
import 'package:shca/services/profile_service.dart';
import 'package:shca/services/session_service.dart';

class ElderlyProfileScreen extends StatefulWidget {
  const ElderlyProfileScreen({
    super.key,
    this.activityMonitor,
    this.profileRepository,
    this.careLinkRepository,
    this.sessionService,
  });

  final ActivityMonitor? activityMonitor;
  final ProfileRepository? profileRepository;
  final CareLinkRepository? careLinkRepository;
  final AppSessionService? sessionService;

  @override
  State<ElderlyProfileScreen> createState() => _ElderlyProfileScreenState();
}

class _ElderlyProfileScreenState extends State<ElderlyProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _medicalController = TextEditingController();
  final _emergencyController = TextEditingController();

  late final ProfileRepository _profileRepository;
  late final CareLinkRepository _careLinkRepository;
  late final AppSessionService _sessionService;

  ElderlyProfile? _profile;
  DateTime? _dateOfBirth;
  String _gender = 'Female';
  String _pairingCode = '';
  String _registeredPhone = '';
  int _linkedCaregiverCount = 0;
  bool _loading = true;
  bool _editing = false;
  bool _saving = false;
  bool _signingOut = false;
  static const _smsChannel = MethodChannel('com.shca.shca/fall_sms');
  bool? _fallSmsEnabled;
  bool _changingFallSms = false;

  Future<void> _loadFallSms() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final enabled = await _smsChannel.invokeMethod<bool>('isEnabled');
      if (mounted) setState(() => _fallSmsEnabled = enabled);
    } on PlatformException catch (_) {
      if (mounted) _showMessage('Could not check fall SMS settings.');
    } on MissingPluginException {
      // Fall SMS is available in the Android phone app.
    }
  }

  Future<void> _setFallSms(bool enabled) async {
    setState(() => _changingFallSms = true);
    try {
      final active = await _smsChannel.invokeMethod<bool>('setEnabled', {
        'enabled': enabled,
      });
      if (!mounted) return;
      setState(() => _fallSmsEnabled = active);
      if (enabled && active != true) {
        _showMessage(
          'Allow SMS permission to send fall texts from this phone.',
        );
      }
    } on PlatformException catch (_) {
      if (mounted) _showMessage('Could not change fall SMS settings.');
    } finally {
      if (mounted) setState(() => _changingFallSms = false);
    }
  }

  String? _error;

  @override
  void initState() {
    super.initState();
    _profileRepository =
        widget.profileRepository ?? FirestoreProfileRepository();
    _careLinkRepository =
        widget.careLinkRepository ?? FirestoreCareLinkRepository();
    _sessionService = widget.sessionService ?? AppSessionService();
    unawaited(_load());
    unawaited(_loadFallSms());
  }

  @override
  void dispose() {
    _nameController.dispose();
    _medicalController.dispose();
    _emergencyController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw StateError('Please sign in again.');
      final results = await Future.wait<Object?>(<Future<Object?>>[
        FirebaseFirestore.instance.collection('users').doc(user.uid).get(),
        _profileRepository.loadElderlyProfile(user.uid),
        _careLinkRepository.loadLinkedCaregiverIds(user.uid),
      ]);
      final userDocument = results[0] as DocumentSnapshot<Map<String, dynamic>>;
      final profile = results[1] as ElderlyProfile?;
      final caregivers = results[2] as List<String>;
      if (profile == null) {
        throw StateError('The elderly profile is not ready.');
      }
      final userData = userDocument.data() ?? const <String, dynamic>{};
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _nameController.text = profile.fullName;
        _medicalController.text = profile.medicalCondition;
        _emergencyController.text = profile.emergencyPhone;
        _dateOfBirth = DateTime.tryParse(profile.dateOfBirth);
        _gender = profile.gender.isEmpty ? 'Female' : profile.gender;
        _pairingCode = (userData['pairingCode'] as String?) ?? '';
        _registeredPhone = (userData['phone'] as String?) ?? '';
        _linkedCaregiverCount = caregivers.length;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _chooseBirthDate() async {
    final now = DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: _dateOfBirth ?? DateTime(now.year - 65),
      firstDate: DateTime(1900),
      lastDate: now,
      helpText: 'Select date of birth',
    );
    if (selected != null) setState(() => _dateOfBirth = selected);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_dateOfBirth == null) {
      _showMessage('Please select your date of birth.');
      return;
    }
    if (isSamePhoneNumber(_emergencyController.text, _registeredPhone)) {
      _showMessage('Use a trusted person’s number, not your own phone number.');
      return;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() => _saving = true);
    try {
      final updated = ElderlyProfile(
        userId: user.uid,
        fullName: _nameController.text.trim(),
        email: _profile?.email ?? user.email ?? '',
        dateOfBirth: _formatIsoDate(_dateOfBirth!),
        gender: _gender,
        emergencyPhone: _emergencyController.text.trim(),
        medicalCondition: _medicalController.text.trim(),
      );
      await _profileRepository.saveElderlyProfile(updated);
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update(
        <String, dynamic>{'fullName': updated.fullName},
      );
      if (!mounted) return;
      setState(() {
        _profile = updated;
        _editing = false;
      });
      _showMessage('Profile updated successfully.');
    } catch (error) {
      if (mounted) {
        _showMessage('Profile could not be saved. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _signOut() async {
    if (_signingOut) return;
    setState(() => _signingOut = true);
    try {
      await _sessionService.signOut(caregiver: false);
      if (!mounted) return;
      Navigator.of(
        context,
        rootNavigator: true,
      ).pushNamedAndRemoveUntil('/login', (_) => false);
    } catch (_) {
      _showMessage('Could not log out. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _signingOut = false);
    }
  }

  Future<void> _openChangePassword() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute<bool>(
        builder: (_) => const ChangePasswordScreen(
          roleLabel: 'Elderly',
          accentColor: elderlyOrange,
          backgroundColor: elderlyPageBackground,
        ),
      ),
    );
    if (changed == true && mounted) {
      _showMessage('Password changed successfully.');
    }
  }

  void _goHome() {
    if (Navigator.canPop(context)) {
      Navigator.pop(context, true);
    } else {
      Navigator.pushReplacementNamed(context, '/home');
    }
  }

  void _openMonitoring() {
    final monitor = widget.activityMonitor ?? phoneActivityMonitor();
    Navigator.pushReplacement<void, bool>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ElderlyMonitoringScreen(activityMonitor: monitor),
      ),
      result: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: elderlyPageBackground,
      body: SafeArea(
        child: Column(
          children: [
            const ElderlyPageHeader(title: 'Profile'),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
      bottomNavigationBar: ElderlyBottomNavigation(
        selectedIndex: 3,
        onHome: _goHome,
        onMedicine: () =>
            Navigator.pushReplacementNamed(context, '/medication'),
        onMonitor: _openMonitoring,
        onProfile: () {},
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: elderlyOrange),
      );
    }
    if (_error != null || _profile == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 52, color: elderlyRed),
              const SizedBox(height: 10),
              const Text(
                'Profile could not be loaded',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('Try Again')),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      color: elderlyOrange,
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
        children: [
          Center(
            child: Container(
              width: 108,
              height: 108,
              decoration: BoxDecoration(
                color: const Color(0xFFFFE4CC),
                shape: BoxShape.circle,
                border: Border.all(color: elderlyOrange, width: 3),
              ),
              child: const Icon(
                Icons.person_rounded,
                color: elderlyOrange,
                size: 72,
              ),
            ),
          ),
          const SizedBox(height: 11),
          Text(
            _profile!.fullName,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
          ),
          const Text(
            'Elderly account',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 20),
          if (_editing) _buildEditForm() else _buildProfileInformation(),
          const SizedBox(height: 16),
          if (!_editing)
            Column(
              children: [
                OutlinedButton.icon(
                  key: const Key('elderly-change-password'),
                  onPressed: _openChangePassword,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: elderlyOrange,
                    minimumSize: const Size(double.infinity, 52),
                    side: const BorderSide(color: elderlyOrange),
                  ),
                  icon: const Icon(Icons.lock_reset_rounded),
                  label: const Text('Change Password'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        key: const Key('edit-elderly-profile'),
                        onPressed: () => setState(() => _editing = true),
                        style: FilledButton.styleFrom(
                          backgroundColor: elderlyOrange,
                          minimumSize: const Size(0, 52),
                        ),
                        icon: const Icon(Icons.edit_rounded),
                        label: const Text('Edit Profile'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('elderly-logout'),
                        onPressed: _signingOut ? null : _signOut,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: elderlyRed,
                          minimumSize: const Size(0, 52),
                          side: const BorderSide(color: elderlyRed),
                        ),
                        icon: _signingOut
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
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

  Widget _buildProfileInformation() {
    final age = _ageFromDate(_dateOfBirth);
    return Column(
      children: [
        _ProfileSection(
          title: 'Personal Information',
          children: [
            _InfoRow(
              icon: Icons.person_outline,
              label: 'Full name',
              value: _profile!.fullName,
            ),
            _InfoRow(
              icon: Icons.email_outlined,
              label: 'Email',
              value: _profile!.email,
            ),
            _InfoRow(
              icon: Icons.cake_outlined,
              label: 'Age and gender',
              value:
                  '${age == null ? 'Not provided' : '$age years old'} • ${_profile!.gender}',
            ),
          ],
        ),
        const SizedBox(height: 13),
        _ProfileSection(
          title: 'Smartwatch',
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.watch_rounded, color: elderlyOrange),
              title: const Text('Connect smartwatch'),
              subtitle: const Text(
                'Use the code on your watch to sign in without typing a password',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      ConnectWatchScreen(accountName: _profile!.fullName),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 13),
        _ProfileSection(
          title: 'Medical Information',
          children: [
            _InfoRow(
              icon: Icons.medical_information_outlined,
              label: 'Medical condition',
              value: _profile!.medicalCondition.isEmpty
                  ? 'None provided'
                  : _profile!.medicalCondition,
            ),
          ],
        ),
        const SizedBox(height: 13),
        _ProfileSection(
          title: 'Emergency Information',
          children: [
            _InfoRow(
              icon: Icons.phone_in_talk_outlined,
              label: 'Emergency contact',
              value: _profile!.emergencyPhone.isEmpty
                  ? 'Not provided'
                  : _profile!.emergencyPhone,
              valueColor: elderlyGreen,
            ),
            _InfoRow(
              icon: Icons.people_outline_rounded,
              label: 'Linked caregivers',
              value: '$_linkedCaregiverCount connected',
            ),
            if (_fallSmsEnabled != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Send fall and SOS alerts by SMS'),
                subtitle: const Text(
                  'Text linked caregivers who enable SMS alerts. This uses your phone plan.',
                ),
                value: _fallSmsEnabled!,
                onChanged: _changingFallSms ? null : _setFallSms,
              ),
            const EmergencyLocationSettings(),
            _linkCodeRow(),
          ],
        ),
      ],
    );
  }

  Widget _linkCodeRow() {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          const Icon(Icons.key_rounded, color: elderlyOrange),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Caregiver link code',
                  style: TextStyle(color: Colors.black54, fontSize: 12),
                ),
                Text(
                  'Share only with someone you trust',
                  style: TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
          SelectableText(
            _pairingCode.isEmpty ? 'Not ready' : _pairingCode,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.3,
            ),
          ),
          if (_pairingCode.isNotEmpty)
            IconButton(
              tooltip: 'Copy caregiver link code',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _pairingCode));
                if (mounted) _showMessage('Caregiver link code copied.');
              },
              icon: const Icon(Icons.copy_rounded),
            ),
        ],
      ),
    );
  }

  Widget _buildEditForm() {
    return Form(
      key: _formKey,
      child: Column(
        children: [
          elderlySectionCard(
            child: Column(
              children: [
                TextFormField(
                  key: const Key('profile-full-name'),
                  controller: _nameController,
                  validator: _required,
                  decoration: const InputDecoration(
                    labelText: 'Full name',
                    prefixIcon: Icon(Icons.person_outline),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 13),
                InkWell(
                  onTap: _chooseBirthDate,
                  borderRadius: BorderRadius.circular(12),
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Date of birth',
                      prefixIcon: Icon(Icons.cake_outlined),
                      border: OutlineInputBorder(),
                    ),
                    child: Text(
                      _dateOfBirth == null
                          ? 'Select date'
                          : _formatDisplayDate(_dateOfBirth!),
                    ),
                  ),
                ),
                const SizedBox(height: 13),
                DropdownButtonFormField<String>(
                  initialValue: _gender,
                  decoration: const InputDecoration(
                    labelText: 'Gender',
                    prefixIcon: Icon(Icons.wc_rounded),
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'Female', child: Text('Female')),
                    DropdownMenuItem(value: 'Male', child: Text('Male')),
                    DropdownMenuItem(
                      value: 'Prefer not to say',
                      child: Text('Prefer not to say'),
                    ),
                  ],
                  onChanged: (value) => setState(() => _gender = value!),
                ),
                const SizedBox(height: 13),
                TextFormField(
                  controller: _medicalController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Medical condition',
                    hintText: 'Example: Diabetes, high blood pressure',
                    prefixIcon: Icon(Icons.medical_information_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 13),
                TextFormField(
                  key: const Key('profile-emergency-phone'),
                  controller: _emergencyController,
                  validator: _required,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Emergency contact number',
                    prefixIcon: Icon(Icons.phone_in_talk_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                          _editing = false;
                          _restoreControllers();
                        }),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 52),
                  ),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  key: const Key('save-elderly-profile'),
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: elderlyOrange,
                    minimumSize: const Size(0, 52),
                  ),
                  icon: _saving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(_saving ? 'Saving…' : 'Save Changes'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _restoreControllers() {
    final profile = _profile!;
    _nameController.text = profile.fullName;
    _medicalController.text = profile.medicalCondition;
    _emergencyController.text = profile.emergencyPhone;
    _dateOfBirth = DateTime.tryParse(profile.dateOfBirth);
    _gender = profile.gender.isEmpty ? 'Female' : profile.gender;
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'This field is required.' : null;

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _ProfileSection extends StatelessWidget {
  const _ProfileSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 3, bottom: 8),
          child: Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
          ),
        ),
        elderlySectionCard(
          child: Column(
            children: [
              for (var index = 0; index < children.length; index++) ...[
                children[index],
                if (index < children.length - 1) const Divider(height: 22),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, color: elderlyOrange, size: 23),
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
              style: TextStyle(
                color: valueColor ?? elderlyInk,
                fontSize: 15,
                fontWeight: FontWeight.w800,
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

int? _ageFromDate(DateTime? birthDate) {
  if (birthDate == null) return null;
  final today = DateTime.now();
  var age = today.year - birthDate.year;
  if (today.month < birthDate.month ||
      (today.month == birthDate.month && today.day < birthDate.day)) {
    age--;
  }
  return age;
}

String _formatIsoDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

String _formatDisplayDate(DateTime value) =>
    '${value.day.toString().padLeft(2, '0')}/'
    '${value.month.toString().padLeft(2, '0')}/${value.year}';
