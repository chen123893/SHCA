import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shca/services/care_link_service.dart';

class ChooseRoleScreen extends StatefulWidget {
  const ChooseRoleScreen({super.key});

  @override
  State<ChooseRoleScreen> createState() => _ChooseRoleScreenState();
}

class _ChooseRoleScreenState extends State<ChooseRoleScreen> {
  static const Color pageBgColor = Color(0xFFFFF9F2);
  static const Color cardBgColor = Color(0xFFFDE4CE);
  static const Color peachAccent = Color(0xFFEE9B61);

  String? _selectedRole;
  bool _isLoading = false;

  Future<void> _selectAndSubmitRole(String role) async {
    setState(() {
      _selectedRole = role;
      _isLoading = true;
    });

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;

      final userReference = FirebaseFirestore.instance
          .collection('users')
          .doc(uid);
      final current = await userReference.get();
      final currentData = current.data() ?? const <String, dynamic>{};
      final Map<String, dynamic> updateData = {
        'role': role,
        'isProfileComplete': false,
      };
      final previousRole = currentData['role'] as String?;
      if (role == 'caregiver' && previousRole == 'elderly') {
        final pairingCode = (currentData['pairingCode'] as String?)?.trim();
        final email = (currentData['email'] as String?)?.trim();
        final batch = FirebaseFirestore.instance.batch();
        if (pairingCode != null && pairingCode.isNotEmpty) {
          batch.delete(
            FirebaseFirestore.instance
                .collection('care_link_lookups')
                .doc(careLinkCodeLookupId(pairingCode)),
          );
        }
        if (email != null && email.isNotEmpty) {
          batch.delete(
            FirebaseFirestore.instance
                .collection('care_link_lookups')
                .doc(careLinkEmailLookupId(email)),
          );
        }
        updateData['pairingCode'] = FieldValue.delete();
        batch.update(userReference, updateData);
        await batch.commit();
      } else {
        await userReference.update(updateData);
      }

      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/pairing');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.redAccent),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: pageBgColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: Color(0xFF1C1C1C),
          ),
          onPressed: () {
            if (Navigator.canPop(context)) {
              Navigator.pop(context);
            } else {
              Navigator.pushReplacementNamed(context, '/login');
            }
          },
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 10.0),
          child: Column(
            children: [
              const Spacer(flex: 1),

              // Banner Illustration
              Center(
                child: Image.asset(
                  'assets/images/login_icon.png',
                  height: 180,
                  fit: BoxFit.contain,
                ),
              ),

              const SizedBox(height: 32),

              // Title
              const Text(
                'Choose Your Role',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1C1C1C),
                ),
              ),

              const SizedBox(height: 36),

              // Side-by-Side Role Cards
              Row(
                children: [
                  Expanded(
                    child: _buildRoleCard(
                      roleValue: 'elderly',
                      title: 'Elderly',
                      icon: Icons.elderly,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _buildRoleCard(
                      roleValue: 'caregiver',
                      title: 'Caregiver',
                      icon: Icons.health_and_safety,
                    ),
                  ),
                ],
              ),

              if (_isLoading) ...[
                const SizedBox(height: 24),
                const CircularProgressIndicator(color: peachAccent),
              ],

              const Spacer(flex: 2),

              // Bottom Right Step Indicator
              Align(
                alignment: Alignment.centerRight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Step 1 of 2',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF2D2D2D),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 14,
                          height: 14,
                          decoration: const BoxDecoration(
                            color: peachAccent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        Container(
                          width: 32,
                          height: 2,
                          color: peachAccent.withValues(alpha: 0.5),
                        ),
                        Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: peachAccent, width: 2),
                          ),
                        ),
                      ],
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

  Widget _buildRoleCard({
    required String roleValue,
    required String title,
    required IconData icon,
  }) {
    final bool isSelected = _selectedRole == roleValue;

    return GestureDetector(
      onTap: _isLoading ? null : () => _selectAndSubmitRole(roleValue),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 210,
        decoration: BoxDecoration(
          color: cardBgColor,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: isSelected ? peachAccent : Colors.transparent,
            width: 2.5,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: const BoxDecoration(
                color: Color(0xFFFFF6ED),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 54, color: peachAccent),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1C1C1C),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
