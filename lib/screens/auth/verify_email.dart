import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shca/services/session_service.dart';

class VerifyEmailScreen extends StatefulWidget {
  const VerifyEmailScreen({super.key});

  // Keep this screen's changing values in its own state object.
  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
  bool isEmailVerified = false;
  bool _signingOut = false;
  Timer? timer;

  // Start rechecking whether the account email has been verified.
  @override
  void initState() {
    super.initState();

    // Check if already verified
    isEmailVerified = FirebaseAuth.instance.currentUser?.emailVerified ?? false;

    if (!isEmailVerified) {
      // Periodically check if user clicked the email link
      timer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => _checkEmailVerified(),
      );
    }
  }

  // Reload the Firebase user and continue once the email is verified.
  Future<void> _checkEmailVerified() async {
    final user = FirebaseAuth.instance.currentUser;
    await user?.reload(); // Refresh user state from Firebase

    setState(() {
      isEmailVerified =
          FirebaseAuth.instance.currentUser?.emailVerified ?? false;
    });

    if (isEmailVerified) {
      timer?.cancel();
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/choose-role');
    }
  }

  // Cancel the timers and subscriptions, then release the controllers when this page is
  // removed.
  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  // Sign out of the unverified account and return to login.
  Future<void> _backToLogin() async {
    if (_signingOut) return;
    setState(() => _signingOut = true);
    try {
      await AppSessionService().signOut(caregiver: false);
      if (!mounted) return;
      Navigator.of(
        context,
        rootNavigator: true,
      ).pushNamedAndRemoveUntil('/login', (_) => false);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not return to login. Please try again.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _signingOut = false);
    }
  }

  // Show the email verification instructions and recheck actions.
  @override
  Widget build(BuildContext context) {
    const Color primaryColor = Color(0xFFE85D4A);

    return Scaffold(
      backgroundColor: const Color(0xFFFFF8F5),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.mark_email_unread_outlined,
                size: 100,
                color: primaryColor,
              ),
              const SizedBox(height: 24),
              const Text(
                'Verify Your Email',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(
                'We sent a verification link to ${FirebaseAuth.instance.currentUser?.email}. Please check your inbox and click the link.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: Colors.grey[600]),
              ),
              const SizedBox(height: 36),
              ElevatedButton(
                onPressed: _checkEmailVerified,
                style: ElevatedButton.styleFrom(backgroundColor: primaryColor),
                child: const Text(
                  'I Have Verified',
                  style: TextStyle(color: Colors.white),
                ),
              ),
              TextButton(
                onPressed: _signingOut ? null : _backToLogin,
                child: Text(
                  _signingOut
                      ? 'Returning to login…'
                      : 'Cancel / Back to Login',
                  style: const TextStyle(color: primaryColor),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
