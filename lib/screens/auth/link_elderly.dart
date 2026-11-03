import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shca/services/care_link_service.dart';

const Color _pageBackground = Color(0xFFFFF8F0);
const Color _orange = Color(0xFFFF8128);
const Color _ink = Color(0xFF241D19);
const Color _green = Color(0xFF4F9A4B);

class ElderlyLinkReadyScreen extends StatelessWidget {
  const ElderlyLinkReadyScreen({
    super.key,
    required this.fullName,
    required this.email,
    required this.pairingCode,
    required this.emergencyPhone,
  });

  final String fullName;
  final String email;
  final String pairingCode;
  final String emergencyPhone;

  Future<void> _copyCode(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: pairingCode));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Elderly link code copied.')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _pageBackground,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: Colors.transparent,
        title: const Text(
          'Caregiver Connection',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
          child: Column(
            children: [
              Container(
                width: 92,
                height: 92,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFFE6F6EC),
                ),
                child: const Icon(Icons.link_rounded, color: _green, size: 48),
              ),
              const SizedBox(height: 18),
              const Text(
                'Your account is ready',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _ink,
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Share this private code or your registered email with a trusted caregiver.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade700, height: 1.4),
              ),
              const SizedBox(height: 24),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: const Color(0xFFFFCDA7)),
                  boxShadow: const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x14000000),
                      blurRadius: 18,
                      offset: Offset(0, 7),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Text(
                      fullName,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'ELDERLY LINK CODE',
                      style: TextStyle(
                        color: _orange,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.3,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      pairingCode,
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 34,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => _copyCode(context),
                      icon: const Icon(Icons.copy_rounded),
                      label: const Text('Copy code'),
                    ),
                    const Divider(height: 34),
                    _InformationRow(
                      icon: Icons.email_outlined,
                      label: 'Registered email',
                      value: email,
                    ),
                    const SizedBox(height: 14),
                    _InformationRow(
                      icon: Icons.phone_in_talk_outlined,
                      label: 'Emergency contact',
                      value: emergencyPhone,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF1DE),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.shield_outlined, color: _orange),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Only share the code with someone you trust. A linked caregiver can view your emergency contact and safety alerts.',
                        style: TextStyle(height: 1.35),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton.icon(
                  onPressed: () =>
                      Navigator.pushReplacementNamed(context, '/home'),
                  style: FilledButton.styleFrom(backgroundColor: _orange),
                  icon: const Icon(Icons.home_rounded),
                  label: const Text('Go to Elderly Dashboard'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class LinkElderlyScreen extends StatefulWidget {
  const LinkElderlyScreen({
    super.key,
    this.repository,
    this.caregiverId,
    this.initialRelationship = '',
    this.initialLinkedElderly,
  });

  final CareLinkRepository? repository;
  final String? caregiverId;
  final String initialRelationship;
  final LinkedElderly? initialLinkedElderly;

  @override
  State<LinkElderlyScreen> createState() => _LinkElderlyScreenState();
}

class _LinkElderlyScreenState extends State<LinkElderlyScreen> {
  final _formKey = GlobalKey<FormState>();
  final _codeOrEmailController = TextEditingController();
  late final TextEditingController _relationshipController;
  late final CareLinkRepository _repository;
  bool _submitting = false;
  LinkedElderly? _linkedElderly;

  @override
  void initState() {
    super.initState();
    _relationshipController = TextEditingController(
      text: widget.initialRelationship,
    );
    _repository = widget.repository ?? FirestoreCareLinkRepository();
    _linkedElderly = widget.initialLinkedElderly;
  }

  @override
  void dispose() {
    _codeOrEmailController.dispose();
    _relationshipController.dispose();
    super.dispose();
  }

  Future<void> _link() async {
    if (!_formKey.currentState!.validate()) return;
    final caregiverId =
        widget.caregiverId ?? FirebaseAuth.instance.currentUser?.uid;
    if (caregiverId == null) {
      _showError('Please sign in as a caregiver before linking.');
      return;
    }

    setState(() => _submitting = true);
    try {
      final result = await _repository.linkElderly(
        caregiverId: caregiverId,
        codeOrEmail: _codeOrEmailController.text,
        relationship: _relationshipController.text,
      );
      if (!mounted) return;
      setState(() => _linkedElderly = result);
    } on CareLinkException catch (error) {
      _showError(error.message);
    } catch (error) {
      _showError('The account could not be linked. Please try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
    );
  }

  void _linkAnother() {
    _codeOrEmailController.clear();
    setState(() => _linkedElderly = null);
  }

  @override
  Widget build(BuildContext context) {
    final result = _linkedElderly;
    return Scaffold(
      backgroundColor: _pageBackground,
      appBar: AppBar(
        backgroundColor: const Color(0xFFFFB87D),
        title: Text(
          result == null ? 'Link Elderly' : 'Link Successful',
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: SafeArea(
        child: result == null ? _buildLinkForm() : _buildSuccess(result),
      ),
    );
  }

  Widget _buildLinkForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 30),
      child: Form(
        key: _formKey,
        child: Column(
          children: [
            const CircleAvatar(
              radius: 46,
              backgroundColor: Color(0xFFFFE0B8),
              child: Icon(Icons.elderly_rounded, color: _orange, size: 50),
            ),
            const SizedBox(height: 18),
            const Text(
              'Connect to an Elderly Account',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w900,
                color: _ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Ask the elderly user for the private six-character code shown after registration, or use their registered email.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade700, height: 1.4),
            ),
            const SizedBox(height: 24),
            TextFormField(
              key: const Key('elderly-link-input'),
              controller: _codeOrEmailController,
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              decoration: _inputDecoration(
                label: 'Elderly link code or email',
                hint: 'ABC234 or elderly@email.com',
                icon: Icons.key_rounded,
              ),
              validator: (value) {
                final input = value?.trim() ?? '';
                if (input.isEmpty) {
                  return 'Enter the elderly link code or email.';
                }
                if (!input.contains('@') &&
                    normalisePairingCode(input).length != 6) {
                  return 'The elderly link code contains six characters.';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              key: const Key('caregiver-relationship-input'),
              controller: _relationshipController,
              textCapitalization: TextCapitalization.words,
              decoration: _inputDecoration(
                label: 'Relationship with elderly',
                hint: 'Daughter, son, nurse...',
                icon: Icons.people_alt_outlined,
              ),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter your relationship to the elderly user.'
                  : null,
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF1DE),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline_rounded, color: _orange),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'The emergency contact number is shown only after a successful link.',
                      style: TextStyle(height: 1.35),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: FilledButton.icon(
                key: const Key('link-elderly-button'),
                onPressed: _submitting ? null : _link,
                style: FilledButton.styleFrom(backgroundColor: _orange),
                icon: _submitting
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.link_rounded),
                label: Text(
                  _submitting ? 'Linking...' : 'Link Elderly Account',
                ),
              ),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: _submitting
                  ? null
                  : () => Navigator.pushReplacementNamed(context, '/home'),
              child: const Text('Link later'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuccess(LinkedElderly elderly) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 30),
      child: Column(
        children: [
          const CircleAvatar(
            radius: 48,
            backgroundColor: Color(0xFFE5F6EA),
            child: Icon(Icons.check_rounded, color: _green, size: 58),
          ),
          const SizedBox(height: 18),
          const Text(
            'Elderly Account Linked',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _ink,
              fontSize: 26,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'You can now view safety information and emergency alerts for this elderly user.',
            textAlign: TextAlign.center,
            style: TextStyle(height: 1.4),
          ),
          const SizedBox(height: 24),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFE8DED6)),
            ),
            child: Column(
              children: [
                const CircleAvatar(
                  radius: 34,
                  backgroundColor: Color(0xFFFFE0B8),
                  child: Icon(Icons.elderly_rounded, color: _orange, size: 38),
                ),
                const SizedBox(height: 12),
                Text(
                  elderly.fullName,
                  key: const Key('linked-elderly-name'),
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if (elderly.relationship.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    elderly.relationship,
                    style: const TextStyle(color: _green),
                  ),
                ],
                const Divider(height: 30),
                _InformationRow(
                  icon: Icons.email_outlined,
                  label: 'Registered email',
                  value: elderly.email,
                ),
                const SizedBox(height: 14),
                _InformationRow(
                  key: const Key('linked-emergency-phone'),
                  icon: Icons.phone_in_talk_outlined,
                  label: 'Emergency contact number',
                  value: elderly.emergencyPhone.isEmpty
                      ? 'Not provided'
                      : elderly.emergencyPhone,
                  trailing: elderly.emergencyPhone.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Copy emergency contact number',
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: elderly.emergencyPhone),
                            );
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Emergency contact number copied.',
                                ),
                              ),
                            );
                          },
                          icon: const Icon(Icons.copy_rounded),
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: FilledButton(
              onPressed: () => Navigator.pushNamedAndRemoveUntil(
                context,
                '/home',
                (route) => false,
              ),
              style: FilledButton.styleFrom(backgroundColor: _orange),
              child: const Text('Go to Caregiver Dashboard'),
            ),
          ),
          TextButton.icon(
            onPressed: _linkAnother,
            icon: const Icon(Icons.add_link_rounded),
            label: const Text('Link another elderly account'),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration({
    required String label,
    required String hint,
    required IconData icon,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(icon),
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFFE2DAD4)),
      ),
    );
  }
}

class _InformationRow extends StatelessWidget {
  const _InformationRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final String value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        CircleAvatar(
          radius: 20,
          backgroundColor: const Color(0xFFFFF1DE),
          child: Icon(icon, color: _orange, size: 21),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 2),
              SelectableText(
                value,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}
