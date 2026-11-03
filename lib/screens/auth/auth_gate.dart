import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shca/screens/auth/choose_role_screen.dart';
import 'package:shca/screens/auth/home_router.dart';
import 'package:shca/screens/auth/login.dart';
import 'package:shca/screens/auth/pairing.dart';
import 'package:shca/screens/auth/verify_email.dart';

/// Restores the correct signed-in screen when the app is opened again.
///
/// Firebase Auth already persists mobile sessions, so a separate cosmetic
/// "remember me" preference is neither necessary nor accurate.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnapshot) {
        if (authSnapshot.connectionState == ConnectionState.waiting) {
          return const _AuthLoadingScreen();
        }
        final user = authSnapshot.data;
        if (user == null) return const LoginScreen();
        if (!user.emailVerified) return const VerifyEmailScreen();

        return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          future: FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .get(),
          builder: (context, userSnapshot) {
            if (userSnapshot.connectionState != ConnectionState.done) {
              return const _AuthLoadingScreen();
            }
            if (userSnapshot.hasError) {
              return _AuthErrorScreen(
                onRetry: () {
                  Navigator.pushNamedAndRemoveUntil(context, '/', (_) => false);
                },
              );
            }
            final data = userSnapshot.data?.data();
            if (data == null || data['role'] == null) {
              return const ChooseRoleScreen();
            }
            if (data['isProfileComplete'] != true) {
              return const PairingScreen();
            }
            return const RoleHomeRouter();
          },
        );
      },
    );
  }
}

class _AuthLoadingScreen extends StatelessWidget {
  const _AuthLoadingScreen();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class _AuthErrorScreen extends StatelessWidget {
  const _AuthErrorScreen({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 52),
            const SizedBox(height: 14),
            const Text(
              'Your account could not be loaded.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    ),
  );
}
