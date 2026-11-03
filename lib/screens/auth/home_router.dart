import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shca/screens/auth/caregiver_dashboard.dart';
import 'package:shca/screens/auth/elderly_home.dart';
import 'package:shca/screens/auth/pairing.dart';

class RoleHomeRouter extends StatelessWidget {
  const RoleHomeRouter({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Scaffold(
        body: Center(child: Text('Please sign in to continue.')),
      );
    }

    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final data = snapshot.data?.data();
        if (data == null || data['isProfileComplete'] != true) {
          return const PairingScreen();
        }
        return data['role'] == 'caregiver'
            ? const CaregiverDashboardScreen()
            : const ElderlyHomeScreen();
      },
    );
  }
}
