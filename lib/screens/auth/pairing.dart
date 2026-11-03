import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shca/screens/auth/link_elderly.dart';
import 'package:shca/services/care_link_service.dart';
import 'package:shca/services/profile_service.dart';
import 'package:shca/services/push_notification_service.dart';

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key, this.repository, this.profileRepository});

  final CareLinkRepository? repository;
  final ProfileRepository? profileRepository;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  static const Color _pageBackground = Color(0xFFFFF9F2);
  static const Color _orange = Color(0xFFFF8128);
  static const Color _ink = Color(0xFF241D19);

  final _formKey = GlobalKey<FormState>();
  late final CareLinkRepository _repository;
  late final ProfileRepository _profileRepository;
  String? _userRole;
  String? _loadError;
  bool _isFetchingRole = true;
  bool _isSubmitting = false;
  bool _linkNowRequested = false;
  String _registeredPhone = '';

  final _elderlyNameController = TextEditingController();
  final _emergencyPhoneController = TextEditingController();
  final _medicalController = TextEditingController();
  String _selectedGender = 'Female';
  DateTime? _selectedDateOfBirth;

  final _caregiverNameController = TextEditingController();
  final _relationshipController = TextEditingController();
  final _linkCodeController = TextEditingController();
  bool _pushAlert = true;
  bool _medicationEmailAlert = true;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? FirestoreCareLinkRepository();
    _profileRepository =
        widget.profileRepository ?? FirestoreProfileRepository();
    _fetchUserRole();
  }

  @override
  void dispose() {
    _elderlyNameController.dispose();
    _emergencyPhoneController.dispose();
    _medicalController.dispose();
    _caregiverNameController.dispose();
    _relationshipController.dispose();
    _linkCodeController.dispose();
    super.dispose();
  }

  Future<void> _fetchUserRole() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) {
        throw StateError('Please sign in to finish your profile.');
      }
      final document = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final data = document.data();
      final role = data?['role'] as String?;
      if (role != 'elderly' && role != 'caregiver') {
        throw StateError('Choose an elderly or caregiver role first.');
      }
      final elderlyProfile = role == 'elderly'
          ? await _profileRepository.loadElderlyProfile(uid)
          : null;
      final caregiverProfile = role == 'caregiver'
          ? await _profileRepository.loadCaregiverProfile(uid)
          : null;
      if (!mounted) return;
      setState(() {
        _userRole = role;
        _registeredPhone = (data?['phone'] as String?) ?? '';
        _elderlyNameController.text = (data?['fullName'] as String?) ?? '';
        _caregiverNameController.text = (data?['fullName'] as String?) ?? '';
        if (elderlyProfile != null) {
          _emergencyPhoneController.text = elderlyProfile.emergencyPhone;
          _medicalController.text = elderlyProfile.medicalCondition;
          if (elderlyProfile.gender.isNotEmpty) {
            _selectedGender = elderlyProfile.gender;
          }
          _selectedDateOfBirth = DateTime.tryParse(elderlyProfile.dateOfBirth);
        }
        if (caregiverProfile != null) {
          _pushAlert = caregiverProfile.pushAlert;
          _medicationEmailAlert = caregiverProfile.medicationEmailAlert;
        }
      });
    } catch (error) {
      if (mounted) setState(() => _loadError = error.toString());
    } finally {
      if (mounted) setState(() => _isFetchingRole = false);
    }
  }

  Future<void> _saveElderlyDetails() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedDateOfBirth == null) {
      _showError('Please select the elderly user’s date of birth.');
      return;
    }
    if (isSamePhoneNumber(_emergencyPhoneController.text, _registeredPhone)) {
      _showError(
        'Use a trusted person’s number, not your own registered phone number.',
      );
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw StateError('Please sign in again.');
      final email = user.email?.trim() ?? '';
      final fullName = _elderlyNameController.text.trim();
      final emergencyPhone = _emergencyPhoneController.text.trim();

      await _profileRepository.saveElderlyProfile(
        ElderlyProfile(
          userId: user.uid,
          fullName: fullName,
          email: email,
          dateOfBirth: _formatIsoDate(_selectedDateOfBirth!),
          gender: _selectedGender,
          emergencyPhone: emergencyPhone,
          medicalCondition: _medicalController.text.trim(),
        ),
      );
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .update(<String, dynamic>{
            'fullName': fullName,
            'emailLowercase': email.toLowerCase(),
            'isProfileComplete': true,
            'profileCompletedAt': FieldValue.serverTimestamp(),
          });
      final pairingCode = await _repository.ensurePairingCode(user.uid);

      if (!mounted) return;
      Navigator.pushReplacement<void, void>(
        context,
        MaterialPageRoute<void>(
          builder: (_) => ElderlyLinkReadyScreen(
            fullName: fullName,
            email: email,
            pairingCode: pairingCode,
            emergencyPhone: emergencyPhone,
          ),
        ),
      );
    } catch (error) {
      _showError('The elderly profile could not be saved. Please try again.');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<void> _saveCaregiverDetails({required bool linkNow}) async {
    setState(() => _linkNowRequested = linkNow);
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSubmitting = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw StateError('Please sign in again.');

      final userReference = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid);
      await userReference.update({
        'fullName': _caregiverNameController.text.trim(),
        'emailLowercase': (user.email ?? '').trim().toLowerCase(),
        'isProfileComplete': false,
      });
      await _profileRepository.saveCaregiverProfile(
        CaregiverProfile(
          userId: user.uid,
          pushAlert: _pushAlert,
          smsAlert: false,
          medicationEmailAlert: _medicationEmailAlert,
        ),
      );
      if (_pushAlert) {
        await PushNotificationService.instance.registerCaregiver(user.uid);
      }

      LinkedElderly? linkedElderly;
      if (linkNow) {
        linkedElderly = await _repository.linkElderly(
          caregiverId: user.uid,
          codeOrEmail: _linkCodeController.text,
          relationship: _relationshipController.text,
        );
      }

      await userReference.update({
        'isProfileComplete': true,
        'profileCompletedAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      if (linkedElderly != null) {
        Navigator.pushReplacement<void, void>(
          context,
          MaterialPageRoute<void>(
            builder: (_) => LinkElderlyScreen(
              repository: widget.repository,
              caregiverId: user.uid,
              initialRelationship: _relationshipController.text.trim(),
              initialLinkedElderly: linkedElderly,
            ),
          ),
        );
      } else {
        Navigator.pushReplacementNamed(context, '/home');
      }
    } on CareLinkException catch (error) {
      _showError(error.message);
    } catch (error) {
      _showError('The caregiver profile could not be saved. Please try again.');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isFetchingRole) {
      return const Scaffold(
        backgroundColor: _pageBackground,
        body: Center(child: CircularProgressIndicator(color: _orange)),
      );
    }
    if (_loadError != null) {
      return Scaffold(
        backgroundColor: _pageBackground,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline,
                  color: Colors.redAccent,
                  size: 48,
                ),
                const SizedBox(height: 12),
                Text(_loadError!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () =>
                      Navigator.pushReplacementNamed(context, '/choose-role'),
                  child: const Text('Choose role'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final isElderly = _userRole == 'elderly';
    return Scaffold(
      backgroundColor: _pageBackground,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
          onPressed: () =>
              Navigator.pushReplacementNamed(context, '/choose-role'),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                Container(
                  width: 112,
                  height: 112,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFFFE0B8),
                    border: Border.all(color: _orange, width: 2),
                  ),
                  child: Icon(
                    isElderly
                        ? Icons.elderly_rounded
                        : Icons.health_and_safety_rounded,
                    color: _orange,
                    size: 62,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  isElderly ? 'Elderly Details' : 'Caregiver Details',
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 25,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  isElderly
                      ? 'Set up safety information and a trusted emergency contact.'
                      : 'Set up your profile before linking an elderly account.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.black54, height: 1.35),
                ),
                const SizedBox(height: 24),
                if (isElderly) _buildElderlyForm() else _buildCaregiverForm(),
                const SizedBox(height: 28),
                const Align(
                  alignment: Alignment.centerRight,
                  child: _StepIndicator(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildElderlyForm() {
    return Column(
      children: [
        _buildTextField(
          key: const Key('elderly-full-name'),
          label: 'Full name',
          hint: 'George Wong',
          controller: _elderlyNameController,
          icon: Icons.person_outline_rounded,
          validator: _requiredValidator('Enter the elderly user’s full name.'),
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _buildDateOfBirthPicker()),
            const SizedBox(width: 12),
            Expanded(child: _buildGenderPicker()),
          ],
        ),
        const SizedBox(height: 14),
        _buildTextField(
          key: const Key('elderly-emergency-phone'),
          label: 'Emergency contact number',
          hint: '010-000 0000',
          controller: _emergencyPhoneController,
          icon: Icons.phone_in_talk_outlined,
          keyboardType: TextInputType.phone,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.allow(RegExp(r'[0-9+()\-\s]')),
          ],
          validator: _phoneValidator,
        ),
        const SizedBox(height: 8),
        const Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Use a trusted person’s number, not your own registration number. The SOS dialler will use this contact.',
            style: TextStyle(color: Colors.black54, fontSize: 12, height: 1.35),
          ),
        ),
        const SizedBox(height: 14),
        _buildTextField(
          label: 'Medical conditions (optional)',
          hint: 'Diabetes, high blood pressure...',
          controller: _medicalController,
          icon: Icons.medical_information_outlined,
          maxLines: 3,
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          height: 54,
          child: FilledButton.icon(
            key: const Key('save-elderly-profile'),
            onPressed: _isSubmitting ? null : _saveElderlyDetails,
            style: FilledButton.styleFrom(backgroundColor: _orange),
            icon: _savingIcon(),
            label: Text(
              _isSubmitting ? 'Saving...' : 'Save and Show Link Code',
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCaregiverForm() {
    return Column(
      children: [
        _buildTextField(
          key: const Key('caregiver-full-name'),
          label: 'Full name',
          hint: 'Emilia Wong',
          controller: _caregiverNameController,
          icon: Icons.person_outline_rounded,
          validator: _requiredValidator('Enter your full name.'),
        ),
        const SizedBox(height: 14),
        _buildTextField(
          key: const Key('caregiver-profile-relationship'),
          label: 'Relationship with elderly',
          hint: 'Daughter, son, nurse...',
          controller: _relationshipController,
          icon: Icons.people_alt_outlined,
          validator: _requiredValidator(
            'Enter your relationship to the elderly user.',
          ),
        ),
        const SizedBox(height: 14),
        _buildTextField(
          key: const Key('caregiver-link-input'),
          label: 'Elderly link code or email (optional)',
          hint: 'ABC234 or elderly@email.com',
          controller: _linkCodeController,
          icon: Icons.key_rounded,
          textCapitalization: TextCapitalization.none,
          autocorrect: false,
          validator: (value) {
            final input = value?.trim() ?? '';
            if (_linkNowRequested && input.isEmpty) {
              return 'Enter the elderly link code or email.';
            }
            if (input.isNotEmpty &&
                !input.contains('@') &&
                normalisePairingCode(input).length != 6) {
              return 'The elderly link code contains six characters.';
            }
            return null;
          },
        ),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFE5DDD7)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: Color(0xFFFFF1DE),
                    child: Icon(
                      Icons.notifications_active_outlined,
                      color: _orange,
                    ),
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Emergency Alert Permission',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Choose how you want to receive emergency and medicine reminders.',
                style: TextStyle(color: Colors.black54, fontSize: 12),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  FilterChip(
                    label: const Text('Push alert'),
                    selected: _pushAlert,
                    onSelected: (value) => setState(() => _pushAlert = value),
                  ),
                  FilterChip(
                    label: const Text('Missed-dose email'),
                    selected: _medicationEmailAlert,
                    onSelected: (value) =>
                        setState(() => _medicationEmailAlert = value),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 54,
                child: FilledButton(
                  key: const Key('link-elderly-from-profile'),
                  onPressed: _isSubmitting
                      ? null
                      : () => _saveCaregiverDetails(linkNow: true),
                  style: FilledButton.styleFrom(backgroundColor: _orange),
                  child: Text(_isSubmitting ? 'Linking...' : 'Link Elderly'),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 54,
                child: OutlinedButton(
                  onPressed: _isSubmitting
                      ? null
                      : () => _saveCaregiverDetails(linkNow: false),
                  child: const Text('Link Later'),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTextField({
    Key? key,
    required String label,
    required String hint,
    required TextEditingController controller,
    required IconData icon,
    String? Function(String?)? validator,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    int maxLines = 1,
    TextCapitalization textCapitalization = TextCapitalization.words,
    bool autocorrect = true,
  }) {
    return TextFormField(
      key: key,
      controller: controller,
      validator: validator,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      maxLines: maxLines,
      textCapitalization: textCapitalization,
      autocorrect: autocorrect,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        alignLabelWithHint: maxLines > 1,
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xFFE0D9D4)),
        ),
      ),
    );
  }

  Widget _buildDateOfBirthPicker() {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () async {
        final now = DateTime.now();
        final selected = await showDatePicker(
          context: context,
          initialDate: _selectedDateOfBirth ?? DateTime(now.year - 70),
          firstDate: DateTime(1900),
          lastDate: now,
          helpText: 'Select date of birth',
        );
        if (selected != null) setState(() => _selectedDateOfBirth = selected);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: 'Date of birth',
          prefixIcon: const Icon(Icons.calendar_month_outlined),
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFFE0D9D4)),
          ),
        ),
        child: Text(
          _selectedDateOfBirth == null
              ? 'Select date'
              : _formatFriendlyDate(_selectedDateOfBirth!),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Widget _buildGenderPicker() {
    return DropdownButtonFormField<String>(
      initialValue: _selectedGender,
      decoration: InputDecoration(
        labelText: 'Gender',
        prefixIcon: const Icon(Icons.person_search_outlined),
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xFFE0D9D4)),
        ),
      ),
      items: const <String>['Female', 'Male', 'Other']
          .map((value) => DropdownMenuItem(value: value, child: Text(value)))
          .toList(growable: false),
      onChanged: (value) {
        if (value != null) setState(() => _selectedGender = value);
      },
    );
  }

  String? Function(String?) _requiredValidator(String message) =>
      (value) => value == null || value.trim().isEmpty ? message : null;

  String? _phoneValidator(String? value) {
    final phone = value?.trim() ?? '';
    if (phone.isEmpty) return 'Enter a contact phone number.';
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 9 || digits.length > 15) {
      return 'Enter a valid phone number with 9 to 15 digits.';
    }
    return null;
  }

  String _formatIsoDate(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  String _formatFriendlyDate(DateTime value) {
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

  Widget _savingIcon() => _isSubmitting
      ? const SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(
            color: Colors.white,
            strokeWidth: 2.5,
          ),
        )
      : const Icon(Icons.arrow_forward_rounded);
}

class _StepIndicator extends StatelessWidget {
  const _StepIndicator();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        const Text(
          'Step 2 of 2',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 7),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFFF8128), width: 2),
              ),
            ),
            Container(width: 28, height: 2, color: const Color(0xFFFFC79C)),
            Container(
              width: 12,
              height: 12,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFFFF8128),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
