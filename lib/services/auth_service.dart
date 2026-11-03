import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class EmailLinkAuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Generates custom pattern like 'A12345'
  String _generateNeatUserId() {
    final random = Random();
    final number = random.nextInt(90000) + 10000;
    return 'A$number';
  }

  // Send link and store email + phone temporarily
  Future<void> sendEmailLink({
    required String email,
    required String phone,
  }) async {
    final actionCodeSettings = ActionCodeSettings(
      url: 'https://shca-fyp.firebaseapp.com',
      handleCodeInApp: true,
      androidPackageName: 'com.shca.shca',
      androidInstallApp: true,
      androidMinimumVersion: '12',
    );

    await _auth.sendSignInLinkToEmail(
      email: email,
      actionCodeSettings: actionCodeSettings,
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pendingEmail', email);
    await prefs.setString('pendingPhone', phone);

    debugPrint('Sign-in link sent to $email');
  }

  // Complete sign-in & store user profile in Firestore
  Future<bool> handleIncomingLink(String incomingLink) async {
    if (_auth.isSignInWithEmailLink(incomingLink)) {
      final prefs = await SharedPreferences.getInstance();
      final email = prefs.getString('pendingEmail');
      final phone = prefs.getString('pendingPhone') ?? '';

      if (email != null) {
        final userCredential = await _auth.signInWithEmailLink(
          email: email,
          emailLink: incomingLink,
        );

        final uid = userCredential.user?.uid;
        if (uid != null) {
          final userDoc = FirebaseFirestore.instance
              .collection('users')
              .doc(uid);

          // Updated Firestore document structure
          await userDoc.set({
            'userId':
                _generateNeatUserId(), // Now stores 'A12345' pattern directly
            'email': email,
            'emailLowercase': email.toLowerCase(),
            'phone': phone,
            'role': null,
            'createdAt': FieldValue.serverTimestamp(),
            'isProfileComplete': false,
          }, SetOptions(merge: true));
        }

        await prefs.remove('pendingEmail');
        await prefs.remove('pendingPhone');

        debugPrint('Successfully signed in with email link.');
        return true;
      }
    }
    return false;
  }
}
