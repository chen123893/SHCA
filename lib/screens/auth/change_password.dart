import 'package:flutter/material.dart';
import 'package:shca/services/password_change_service.dart';

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({
    super.key,
    required this.roleLabel,
    required this.accentColor,
    required this.backgroundColor,
    this.passwordChangeService,
  });

  final String roleLabel;
  final Color accentColor;
  final Color backgroundColor;
  final PasswordChangeService? passwordChangeService;

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _currentPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  late final PasswordChangeService _passwordChangeService;
  bool _hideCurrentPassword = true;
  bool _hideNewPassword = true;
  bool _hideConfirmPassword = true;
  bool _saving = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _passwordChangeService =
        widget.passwordChangeService ?? FirebasePasswordChangeService();
  }

  @override
  void dispose() {
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _changePassword() async {
    FocusScope.of(context).unfocus();
    setState(() => _errorMessage = null);
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    try {
      await _passwordChangeService.changePassword(
        currentPassword: _currentPasswordController.text,
        newPassword: _newPasswordController.text,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } on PasswordChangeFailure catch (error) {
      if (mounted) setState(() => _errorMessage = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _errorMessage =
              'Password could not be changed. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _validateCurrentPassword(String? value) {
    if (value == null || value.isEmpty) return 'Enter your current password.';
    return null;
  }

  String? _validateNewPassword(String? value) {
    final password = value ?? '';
    if (password.isEmpty) return 'Enter a new password.';
    if (password.length < 8) return 'Use at least 8 characters.';
    if (!RegExp(r'[A-Z]').hasMatch(password)) {
      return 'Add at least 1 uppercase letter.';
    }
    if (!RegExp(r'[a-z]').hasMatch(password)) {
      return 'Add at least 1 lowercase letter.';
    }
    if (!RegExp(r'[0-9]').hasMatch(password)) {
      return 'Add at least 1 number.';
    }
    if (!RegExp(r'[!@#$%^&*(),.?":{}|<>]').hasMatch(password)) {
      return 'Add at least 1 special character.';
    }
    if (password == _currentPasswordController.text) {
      return 'Choose a password different from the current one.';
    }
    return null;
  }

  String? _validateConfirmation(String? value) {
    if (value == null || value.isEmpty) return 'Confirm the new password.';
    if (value != _newPasswordController.text) {
      return 'New passwords do not match.';
    }
    return null;
  }

  InputDecoration _decoration({
    required String label,
    required IconData icon,
    required bool hidden,
    required VoidCallback onToggle,
  }) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
      suffixIcon: IconButton(
        tooltip: hidden ? 'Show password' : 'Hide password',
        onPressed: onToggle,
        icon: Icon(
          hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        ),
      ),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: widget.backgroundColor,
      appBar: AppBar(
        backgroundColor: widget.accentColor,
        foregroundColor: Colors.white,
        title: const Text(
          'Change Password',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(22),
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x12000000),
                      blurRadius: 16,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: CircleAvatar(
                        radius: 34,
                        backgroundColor: widget.accentColor.withValues(
                          alpha: 0.14,
                        ),
                        child: Icon(
                          Icons.lock_reset_rounded,
                          size: 40,
                          color: widget.accentColor,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Center(
                      child: Text(
                        'Protect your account',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Center(
                      child: Text(
                        '${widget.roleLabel} account',
                        style: const TextStyle(color: Colors.black54),
                      ),
                    ),
                    const SizedBox(height: 22),
                    TextFormField(
                      key: const Key('current-password'),
                      controller: _currentPasswordController,
                      obscureText: _hideCurrentPassword,
                      autofillHints: const <String>[AutofillHints.password],
                      textInputAction: TextInputAction.next,
                      validator: _validateCurrentPassword,
                      decoration: _decoration(
                        label: 'Current password',
                        icon: Icons.lock_outline_rounded,
                        hidden: _hideCurrentPassword,
                        onToggle: () => setState(
                          () => _hideCurrentPassword = !_hideCurrentPassword,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const Key('new-password'),
                      controller: _newPasswordController,
                      obscureText: _hideNewPassword,
                      autofillHints: const <String>[AutofillHints.newPassword],
                      textInputAction: TextInputAction.next,
                      validator: _validateNewPassword,
                      decoration: _decoration(
                        label: 'New password',
                        icon: Icons.password_rounded,
                        hidden: _hideNewPassword,
                        onToggle: () => setState(
                          () => _hideNewPassword = !_hideNewPassword,
                        ),
                      ),
                    ),
                    const SizedBox(height: 9),
                    const Text(
                      'Use 8+ characters with uppercase, lowercase, a number and a special character.',
                      style: TextStyle(color: Colors.black54, fontSize: 12),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const Key('confirm-new-password'),
                      controller: _confirmPasswordController,
                      obscureText: _hideConfirmPassword,
                      autofillHints: const <String>[AutofillHints.newPassword],
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) {
                        if (!_saving) _changePassword();
                      },
                      validator: _validateConfirmation,
                      decoration: _decoration(
                        label: 'Confirm new password',
                        icon: Icons.verified_user_outlined,
                        hidden: _hideConfirmPassword,
                        onToggle: () => setState(
                          () => _hideConfirmPassword = !_hideConfirmPassword,
                        ),
                      ),
                    ),
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        key: const Key('password-change-error'),
                        width: double.infinity,
                        padding: const EdgeInsets.all(13),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFE7E7),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.error_outline_rounded,
                              color: Color(0xFFB3261E),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _errorMessage!,
                                style: const TextStyle(
                                  color: Color(0xFF8C1D18),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 22),
                    FilledButton.icon(
                      key: const Key('submit-password-change'),
                      onPressed: _saving ? null : _changePassword,
                      style: FilledButton.styleFrom(
                        backgroundColor: widget.accentColor,
                        minimumSize: const Size(double.infinity, 54),
                      ),
                      icon: _saving
                          ? const SizedBox.square(
                              dimension: 19,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.security_rounded),
                      label: Text(
                        _saving ? 'Updating…' : 'Update Password',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
