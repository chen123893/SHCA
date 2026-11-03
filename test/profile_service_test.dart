import 'package:flutter_test/flutter_test.dart';
import 'package:shca/services/profile_service.dart';

void main() {
  test('elderly profile keeps sensitive data outside the user document', () {
    const profile = ElderlyProfile(
      userId: 'elderly-1',
      fullName: 'George Wong',
      email: 'george@example.com',
      dateOfBirth: '1954-06-09',
      gender: 'Male',
      emergencyPhone: '012-345 6789',
      medicalCondition: 'Diabetes',
    );

    final data = profile.toFirestore();
    expect(data['userId'], 'elderly-1');
    expect(data['emergencyContact'], isA<Map<String, dynamic>>());
    expect(
      (data['emergencyContact'] as Map<String, dynamic>)['phone'],
      '012-345 6789',
    );
  });

  test('caregiver preferences use their own profile document', () {
    const profile = CaregiverProfile(
      userId: 'caregiver-1',
      pushAlert: true,
      smsAlert: false,
      medicationEmailAlert: true,
    );
    final restored = CaregiverProfile.fromFirestore(
      profile.userId,
      profile.toFirestore(),
    );

    expect(restored.pushAlert, isTrue);
    expect(restored.smsAlert, isFalse);
    expect(restored.medicationEmailAlert, isTrue);
  });
}
