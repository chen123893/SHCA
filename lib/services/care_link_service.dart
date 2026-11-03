import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shca/services/profile_service.dart';

const String careLinkAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

String normaliseCareLinkInput(String value) => value.trim().toLowerCase();

String normalisePairingCode(String value) =>
    value.trim().replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();

String careLinkEmailLookupId(String email) =>
    'email_${sha256.convert(utf8.encode(normaliseCareLinkInput(email)))}';

String careLinkCodeLookupId(String code) =>
    'code_${normalisePairingCode(code)}';

String normalisePhoneForComparison(String value) {
  var digits = value.replaceAll(RegExp(r'\D'), '');
  if (digits.startsWith('0060')) {
    digits = '0${digits.substring(4)}';
  } else if (digits.startsWith('60')) {
    digits = '0${digits.substring(2)}';
  }
  return digits;
}

bool isSamePhoneNumber(String first, String second) {
  final normalizedFirst = normalisePhoneForComparison(first);
  final normalizedSecond = normalisePhoneForComparison(second);
  return normalizedFirst.isNotEmpty && normalizedFirst == normalizedSecond;
}

String generatePairingCode([Random? random]) {
  final source = random ?? Random.secure();
  return List<String>.generate(
    6,
    (_) => careLinkAlphabet[source.nextInt(careLinkAlphabet.length)],
  ).join();
}

class CareLinkException implements Exception {
  const CareLinkException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LinkedElderly {
  const LinkedElderly({
    required this.id,
    required this.fullName,
    required this.email,
    required this.emergencyPhone,
    required this.relationship,
    this.dateOfBirth = '',
    this.gender = '',
    this.medicalCondition = '',
  });

  final String id;
  final String fullName;
  final String email;
  final String emergencyPhone;
  final String relationship;
  final String dateOfBirth;
  final String gender;
  final String medicalCondition;

  int? get age {
    final birthDate = DateTime.tryParse(dateOfBirth);
    if (birthDate == null) return null;
    final today = DateTime.now();
    var years = today.year - birthDate.year;
    if (today.month < birthDate.month ||
        (today.month == birthDate.month && today.day < birthDate.day)) {
      years--;
    }
    return years >= 0 ? years : null;
  }
}

abstract interface class CareLinkRepository {
  Future<String> ensurePairingCode(String elderlyId);

  Future<LinkedElderly> linkElderly({
    required String caregiverId,
    required String codeOrEmail,
    required String relationship,
  });

  Future<List<LinkedElderly>> loadLinkedElderly(String caregiverId);

  Future<List<String>> loadLinkedCaregiverIds(String elderlyId);

  Future<void> unlinkElderly({
    required String caregiverId,
    required String elderlyId,
  });
}

class FirestoreCareLinkRepository implements CareLinkRepository {
  FirestoreCareLinkRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance,
      _profileRepository = FirestoreProfileRepository(firestore: firestore);

  final FirebaseFirestore _firestore;
  final FirestoreProfileRepository _profileRepository;

  CollectionReference<Map<String, dynamic>> get _users =>
      _firestore.collection('users');

  CollectionReference<Map<String, dynamic>> get _links =>
      _firestore.collection('care_links');

  CollectionReference<Map<String, dynamic>> get _caregiverProfiles =>
      _firestore.collection('caregiver_profiles');

  CollectionReference<Map<String, dynamic>> get _lookups =>
      _firestore.collection('care_link_lookups');

  @override
  Future<String> ensurePairingCode(String elderlyId) async {
    final elderlyReference = _users.doc(elderlyId);
    final existing = await elderlyReference.get();
    final existingData = existing.data();
    if (existingData == null || existingData['role'] != 'elderly') {
      throw const CareLinkException(
        'Only an elderly account can create a link code.',
      );
    }

    final currentCode = (existingData['pairingCode'] as String?)?.trim();
    if (currentCode != null && currentCode.isNotEmpty) {
      await _saveLookupDocuments(
        elderlyId: elderlyId,
        pairingCode: currentCode,
        email: (existingData['email'] as String?) ?? '',
      );
      return currentCode;
    }

    for (var attempt = 0; attempt < 12; attempt++) {
      final candidate = generatePairingCode();
      try {
        await _saveLookupDocuments(
          elderlyId: elderlyId,
          pairingCode: candidate,
          email: (existingData['email'] as String?) ?? '',
          savePairingCodeToUser: true,
        );
        return candidate;
      } on FirebaseException catch (error) {
        // A generated lookup already owned by someone else is rejected by
        // the rules, so generate a different code.
        if (error.code != 'permission-denied') rethrow;
      }
    }

    throw const CareLinkException(
      'A secure link code could not be created. Please try again.',
    );
  }

  Future<void> _saveLookupDocuments({
    required String elderlyId,
    required String pairingCode,
    required String email,
    bool savePairingCodeToUser = false,
  }) async {
    final batch = _firestore.batch();
    if (savePairingCodeToUser) {
      batch.update(_users.doc(elderlyId), <String, dynamic>{
        'pairingCode': pairingCode,
        'pairingCodeCreatedAt': FieldValue.serverTimestamp(),
      });
    }
    batch
        .set(_lookups.doc(careLinkCodeLookupId(pairingCode)), <String, dynamic>{
          'elderlyId': elderlyId,
          'lookupType': 'pairing_code',
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
    if (email.trim().isNotEmpty) {
      batch.set(_lookups.doc(careLinkEmailLookupId(email)), <String, dynamic>{
        'elderlyId': elderlyId,
        'lookupType': 'email_hash',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }
    await batch.commit();
  }

  Future<({String elderlyId, String lookupId})?> _findElderly(
    String input,
  ) async {
    final normalized = normaliseCareLinkInput(input);
    final lookupId = normalized.contains('@')
        ? careLinkEmailLookupId(normalized)
        : careLinkCodeLookupId(input);
    if (!normalized.contains('@') && normalisePairingCode(input).length != 6) {
      return null;
    }
    final result = await _lookups.doc(lookupId).get();
    final elderlyId = result.data()?['elderlyId'] as String?;
    if (elderlyId == null || elderlyId.isEmpty) return null;
    return (elderlyId: elderlyId, lookupId: lookupId);
  }

  @override
  Future<LinkedElderly> linkElderly({
    required String caregiverId,
    required String codeOrEmail,
    required String relationship,
  }) async {
    final cleanedRelationship = relationship.trim();
    if (cleanedRelationship.isEmpty) {
      throw const CareLinkException(
        'Please enter your relationship to the elderly user.',
      );
    }

    final match = await _findElderly(codeOrEmail);
    if (match == null) {
      throw const CareLinkException(
        'No elderly account matches that link code or registered email.',
      );
    }
    final elderlyId = match.elderlyId;
    if (elderlyId == caregiverId) {
      throw const CareLinkException('An account cannot be linked to itself.');
    }

    final caregiverReference = _users.doc(caregiverId);
    final caregiverProfileReference = _caregiverProfiles.doc(caregiverId);
    final linkReference = _links.doc('${caregiverId}_$elderlyId');

    await _firestore.runTransaction((transaction) async {
      final caregiver = await transaction.get(caregiverReference);
      final caregiverProfile = await transaction.get(caregiverProfileReference);
      if (!caregiver.exists || caregiver.data()?['role'] != 'caregiver') {
        throw const CareLinkException(
          'A caregiver account is required to link an elderly user.',
        );
      }
      transaction.set(linkReference, {
        'caregiverId': caregiverId,
        'elderlyId': elderlyId,
        'lookupId': match.lookupId,
        'relationship': cleanedRelationship,
        'status': 'active',
        'caregiverEmail': _caregiverEmail(caregiverId, caregiver.data()),
        'medicationEmailAlertsEnabled': _medicationEmailAlertFrom(
          caregiverProfile.data(),
        ),
        'linkedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    });

    final profile = await _profileRepository.loadElderlyProfile(elderlyId);
    if (profile == null) {
      throw const CareLinkException(
        'The elderly profile is not ready. Ask the elderly user to open the updated app once.',
      );
    }
    return _linkedElderlyFromData(
      id: elderlyId,
      profile: profile,
      relationship: cleanedRelationship,
    );
  }

  @override
  Future<List<LinkedElderly>> loadLinkedElderly(String caregiverId) async {
    final links = await _links
        .where('caregiverId', isEqualTo: caregiverId)
        .where('status', isEqualTo: 'active')
        .get();
    await _syncCaregiverEmailSettings(caregiverId, links.docs);
    final relationships = <String, String>{
      for (final link in links.docs)
        if ((link.data()['elderlyId'] as String?) != null)
          link.data()['elderlyId'] as String:
              (link.data()['relationship'] as String?) ?? '',
    };

    // Compatibility fallback for links created by the earlier array schema.
    if (relationships.isEmpty) {
      final caregiver = await _users.doc(caregiverId).get();
      final legacyIds =
          (caregiver.data()?['linkedElderlyIds'] as List<dynamic>? ??
                  const <dynamic>[])
              .whereType<String>();
      for (final elderlyId in legacyIds) {
        relationships.putIfAbsent(elderlyId, () => '');
      }
    }

    final linked = await Future.wait(
      relationships.entries.map((entry) async {
        final elderlyId = entry.key;
        final profile = await _profileRepository.loadElderlyProfile(elderlyId);
        if (profile == null) return null;
        return _linkedElderlyFromData(
          id: elderlyId,
          profile: profile,
          relationship: entry.value,
        );
      }),
    );

    final values = linked.whereType<LinkedElderly>().toList(growable: false);
    values.sort((a, b) => a.fullName.compareTo(b.fullName));
    return values;
  }

  Future<void> _syncCaregiverEmailSettings(
    String caregiverId,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> links,
  ) async {
    if (links.isEmpty) return;
    try {
      final results = await Future.wait<Object?>(<Future<Object?>>[
        _users.doc(caregiverId).get(),
        _caregiverProfiles.doc(caregiverId).get(),
      ]);
      final user = results[0] as DocumentSnapshot<Map<String, dynamic>>;
      final profile = results[1] as DocumentSnapshot<Map<String, dynamic>>;
      final email = _caregiverEmail(caregiverId, user.data());
      final emailEnabled = _medicationEmailAlertFrom(profile.data());
      if (email.isEmpty) return;

      final batch = _firestore.batch();
      var hasChanges = false;
      for (final link in links) {
        final data = link.data();
        if (data['caregiverEmail'] == email &&
            data['medicationEmailAlertsEnabled'] == emailEnabled) {
          continue;
        }
        hasChanges = true;
        batch.update(link.reference, <String, dynamic>{
          'caregiverEmail': email,
          'medicationEmailAlertsEnabled': emailEnabled,
          'notificationSettingsUpdatedAt': FieldValue.serverTimestamp(),
        });
      }
      if (hasChanges) await batch.commit();
    } on FirebaseException catch (error) {
      // Contact syncing is helpful but must not block the caregiver dashboard.
      debugPrint(
        'Could not sync caregiver email reminder settings: ${error.code}',
      );
    }
  }

  String _caregiverEmail(String caregiverId, Map<String, dynamic>? userData) {
    final storedEmail = (userData?['email'] as String?)?.trim().toLowerCase();
    if (storedEmail?.isNotEmpty == true) return storedEmail!;
    final signedInUser = FirebaseAuth.instance.currentUser;
    if (signedInUser?.uid != caregiverId) return '';
    return signedInUser?.email?.trim().toLowerCase() ?? '';
  }

  @override
  Future<List<String>> loadLinkedCaregiverIds(String elderlyId) async {
    final links = await _links
        .where('elderlyId', isEqualTo: elderlyId)
        .where('status', isEqualTo: 'active')
        .get();
    final ids = links.docs
        .map((document) => document.data()['caregiverId'])
        .whereType<String>()
        .toSet();
    if (ids.isNotEmpty) return ids.toList(growable: false);

    // Compatibility fallback for accounts linked before care_links existed.
    final elderly = await _users.doc(elderlyId).get();
    return (elderly.data()?['linkedCaregiverIds'] as List<dynamic>? ??
            const <dynamic>[])
        .whereType<String>()
        .toSet()
        .toList(growable: false);
  }

  @override
  Future<void> unlinkElderly({
    required String caregiverId,
    required String elderlyId,
  }) async {
    await _links.doc('${caregiverId}_$elderlyId').delete();
  }

  LinkedElderly _linkedElderlyFromData({
    required String id,
    required ElderlyProfile profile,
    required String relationship,
  }) {
    return LinkedElderly(
      id: id,
      fullName: profile.fullName.trim().isEmpty
          ? 'Elderly user'
          : profile.fullName,
      email: profile.email,
      emergencyPhone: profile.emergencyPhone,
      relationship: relationship,
      dateOfBirth: profile.dateOfBirth,
      gender: profile.gender,
      medicalCondition: profile.medicalCondition,
    );
  }
}

bool _medicationEmailAlertFrom(Map<String, dynamic>? data) {
  final preferences = data?['alertPreferences'] ?? data?['alertPermissions'];
  return preferences is Map
      ? (preferences['medicationEmailAlert'] as bool? ?? true)
      : true;
}
