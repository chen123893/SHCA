import 'package:cloud_firestore/cloud_firestore.dart';

class ElderlyProfile {
  const ElderlyProfile({
    required this.userId,
    required this.fullName,
    required this.email,
    required this.dateOfBirth,
    required this.gender,
    required this.emergencyPhone,
    required this.medicalCondition,
  });

  final String userId;
  final String fullName;
  final String email;
  final String dateOfBirth;
  final String gender;
  final String emergencyPhone;
  final String medicalCondition;

  Map<String, dynamic> toFirestore() => <String, dynamic>{
    'userId': userId,
    'fullName': fullName,
    'email': email,
    'dateOfBirth': dateOfBirth,
    'gender': gender,
    'emergencyContact': <String, dynamic>{
      'phone': emergencyPhone,
      'type': 'personal_emergency_contact',
    },
    'medicalCondition': medicalCondition,
  };

  factory ElderlyProfile.fromFirestore(
    String userId,
    Map<String, dynamic> data,
  ) {
    final emergencyContact = data['emergencyContact'];
    return ElderlyProfile(
      userId: userId,
      fullName: (data['fullName'] as String?) ?? 'Elderly user',
      email: (data['email'] as String?) ?? '',
      dateOfBirth: (data['dateOfBirth'] as String?) ?? '',
      gender: (data['gender'] as String?) ?? '',
      emergencyPhone: emergencyContact is Map
          ? (emergencyContact['phone'] as String? ?? '').trim()
          : '',
      medicalCondition: (data['medicalCondition'] as String?) ?? '',
    );
  }
}

class CaregiverProfile {
  const CaregiverProfile({
    required this.userId,
    required this.pushAlert,
    required this.smsAlert,
    this.medicationEmailAlert = true,
  });

  final String userId;
  final bool pushAlert;
  final bool smsAlert;
  final bool medicationEmailAlert;

  Map<String, dynamic> toFirestore() => <String, dynamic>{
    'userId': userId,
    'alertPreferences': <String, dynamic>{
      'pushAlert': pushAlert,
      'smsAlert': smsAlert,
      'medicationEmailAlert': medicationEmailAlert,
    },
  };

  factory CaregiverProfile.fromFirestore(
    String userId,
    Map<String, dynamic> data,
  ) {
    final preferences = data['alertPreferences'] ?? data['alertPermissions'];
    return CaregiverProfile(
      userId: userId,
      pushAlert: preferences is Map
          ? (preferences['pushAlert'] as bool? ?? true)
          : true,
      smsAlert: preferences is Map
          ? (preferences['smsAlert'] as bool? ?? false)
          : false,
      medicationEmailAlert: preferences is Map
          ? (preferences['medicationEmailAlert'] as bool? ?? true)
          : true,
    );
  }
}

abstract interface class ProfileRepository {
  Future<void> saveElderlyProfile(ElderlyProfile profile);

  Future<void> saveCaregiverProfile(CaregiverProfile profile);

  Future<ElderlyProfile?> loadElderlyProfile(String userId);

  Future<CaregiverProfile?> loadCaregiverProfile(String userId);
}

class FirestoreProfileRepository implements ProfileRepository {
  FirestoreProfileRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _users =>
      _firestore.collection('users');

  CollectionReference<Map<String, dynamic>> get _elderlyProfiles =>
      _firestore.collection('elderly_profiles');

  CollectionReference<Map<String, dynamic>> get _caregiverProfiles =>
      _firestore.collection('caregiver_profiles');

  @override
  Future<void> saveElderlyProfile(ElderlyProfile profile) async {
    await _elderlyProfiles.doc(profile.userId).set(<String, dynamic>{
      ...profile.toFirestore(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  @override
  Future<void> saveCaregiverProfile(CaregiverProfile profile) async {
    await _caregiverProfiles.doc(profile.userId).set(<String, dynamic>{
      ...profile.toFirestore(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  @override
  Future<ElderlyProfile?> loadElderlyProfile(String userId) async {
    final profile = await _elderlyProfiles.doc(userId).get();
    final profileData = profile.data();
    if (profileData != null) {
      return ElderlyProfile.fromFirestore(userId, profileData);
    }

    // Compatibility for accounts created before the split profile schema.
    try {
      final legacy = await _users.doc(userId).get();
      final legacyData = legacy.data();
      if (legacyData == null || legacyData['role'] != 'elderly') return null;
      final migrated = ElderlyProfile.fromFirestore(userId, legacyData);
      if (_hasElderlyProfileData(legacyData)) {
        await saveElderlyProfile(migrated);
      }
      return migrated;
    } on FirebaseException {
      // Linked caregivers cannot read the owner's private users document.
      return null;
    }
  }

  @override
  Future<CaregiverProfile?> loadCaregiverProfile(String userId) async {
    final profile = await _caregiverProfiles.doc(userId).get();
    final profileData = profile.data();
    if (profileData != null) {
      return CaregiverProfile.fromFirestore(userId, profileData);
    }

    // Compatibility for accounts created before the split profile schema.
    final legacy = await _users.doc(userId).get();
    final legacyData = legacy.data();
    if (legacyData == null || legacyData['role'] != 'caregiver') return null;
    final migrated = CaregiverProfile.fromFirestore(userId, legacyData);
    if (legacyData['alertPermissions'] is Map) {
      await saveCaregiverProfile(migrated);
    }
    return migrated;
  }

  bool _hasElderlyProfileData(Map<String, dynamic> data) =>
      data.containsKey('dateOfBirth') ||
      data.containsKey('gender') ||
      data.containsKey('emergencyContact') ||
      data.containsKey('medicalCondition');
}
