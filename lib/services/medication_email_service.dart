import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

class MedicationEmailException implements Exception {
  const MedicationEmailException(this.message);

  final String message;

  @override
  String toString() => message;
}

class MedicationEmailResult {
  const MedicationEmailResult({
    required this.sent,
    required this.alreadySent,
    required this.unavailable,
    this.linkedCaregivers = 0,
    this.missingEmail = 0,
    this.disabled = 0,
  });

  final int sent;
  final int alreadySent;
  final int unavailable;
  final int linkedCaregivers;
  final int missingEmail;
  final int disabled;
}

/// Requests a caregiver email from the authenticated SHCA Cloudflare Worker.
///
/// No email-provider secret is placed in the Android app. The Worker reads the
/// medicine and linked caregiver addresses after verifying the Firebase token.
class MedicationEmailService {
  const MedicationEmailService({
    this.baseUrl = const String.fromEnvironment(
      'MEDICATION_IMAGE_API_URL',
      defaultValue:
          'https://shca-medication-images.shca-medication-images.workers.dev',
    ),
  });

  final String baseUrl;

  Future<MedicationEmailResult> sendMissedReminder({
    required String elderlyId,
    required String medicationId,
    DateTime? occurrenceDate,
  }) => _send(
    path: '/v1/medication-reminders/email',
    elderlyId: elderlyId,
    medicationId: medicationId,
    occurrenceDate: occurrenceDate,
  );

  Future<MedicationEmailResult> sendLowStockReminder({
    required String elderlyId,
    required String medicationId,
    DateTime? occurrenceDate,
  }) => _send(
    path: '/v1/medication-stock/email',
    elderlyId: elderlyId,
    medicationId: medicationId,
    occurrenceDate: occurrenceDate,
  );

  Future<MedicationEmailResult> _send({
    required String path,
    required String elderlyId,
    required String medicationId,
    DateTime? occurrenceDate,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.uid != elderlyId) {
      throw const MedicationEmailException(
        'The elderly account must be signed in to send this reminder.',
      );
    }
    final token = await user.getIdToken();
    if (token == null || token.isEmpty) {
      throw const MedicationEmailException(
        'A secure sign-in token could not be created.',
      );
    }
    final date = occurrenceDate ?? DateTime.now();
    final response = await http
        .post(
          _endpoint(path),
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(<String, String>{
            'elderlyId': elderlyId,
            'medicationId': medicationId,
            'occurrenceDate': _dateKey(date),
          }),
        )
        .timeout(const Duration(seconds: 15));
    final decoded = _decode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MedicationEmailException(
        (decoded?['error'] as String?) ??
            'Caregiver email request failed (${response.statusCode}).',
      );
    }
    return MedicationEmailResult(
      sent: (decoded?['sent'] as num?)?.toInt() ?? 0,
      alreadySent: (decoded?['alreadySent'] as num?)?.toInt() ?? 0,
      unavailable: (decoded?['unavailable'] as num?)?.toInt() ?? 0,
      linkedCaregivers: (decoded?['linkedCaregivers'] as num?)?.toInt() ?? 0,
      missingEmail: (decoded?['missingEmail'] as num?)?.toInt() ?? 0,
      disabled: (decoded?['disabled'] as num?)?.toInt() ?? 0,
    );
  }

  Uri _endpoint(String path) {
    final trimmed = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (trimmed.isEmpty) {
      throw const MedicationEmailException(
        'The medication reminder service is not configured.',
      );
    }
    return Uri.parse('$trimmed$path');
  }

  Map<String, dynamic>? _decode(String body) {
    try {
      final value = jsonDecode(body);
      return value is Map<String, dynamic> ? value : null;
    } catch (_) {
      return null;
    }
  }

  String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
