import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

class EmergencyPushResult {
  const EmergencyPushResult({
    required this.accepted,
    required this.unavailable,
    required this.linkedCaregivers,
    this.message,
    this.emailAccepted = 0,
    this.emailUnavailable = 0,
    this.emailError,
  });

  final int accepted;
  final int unavailable;
  final int linkedCaregivers;
  final String? message;
  final int emailAccepted;
  final int emailUnavailable;
  final String? emailError;

  // Acceptance by FCM/Brevo does not confirm that a person has seen the alert.
  bool get delivered => accepted > 0;
  bool get anyChannelAccepted => accepted > 0 || emailAccepted > 0;
  bool get allChannelsAccepted =>
      accepted > 0 &&
      unavailable == 0 &&
      emailAccepted > 0 &&
      emailUnavailable == 0;

  factory EmergencyPushResult.fromJson(Map<String, dynamic> value) =>
      EmergencyPushResult(
        accepted: (value['accepted'] as num?)?.toInt() ?? 0,
        unavailable: (value['unavailable'] as num?)?.toInt() ?? 0,
        linkedCaregivers: (value['linkedCaregivers'] as num?)?.toInt() ?? 0,
        message: value['error'] as String?,
        emailAccepted: (value['emailAccepted'] as num?)?.toInt() ?? 0,
        emailUnavailable: (value['emailUnavailable'] as num?)?.toInt() ?? 0,
        emailError: value['emailError'] as String?,
      );

  String get deliverySummary => [
    accepted > 0
        ? 'Push: accepted by the notification service.'
        : 'Push: ${message ?? "Not accepted. Check the caregiver phone and notification permission."}',
    if (accepted > 0 && unavailable > 0 && message != null) message!,
    emailAccepted > 0
        ? 'Email: accepted by the email service.'
        : 'Email: ${emailError ?? "Acceptance could not be confirmed."}',
    if (emailAccepted > 0 && emailUnavailable > 0 && emailError != null)
      emailError!,
  ].join('\n\n');
}

/// Asks the authenticated SHCA Worker to notify linked caregivers.
///
/// The app supplies only the newly-created alert ID. The Worker verifies its
/// owner and resolves active caregiver links and FCM tokens server-side.
class EmergencyPushService {
  const EmergencyPushService({
    this.baseUrl = const String.fromEnvironment(
      'MEDICATION_IMAGE_API_URL',
      defaultValue:
          'https://shca-medication-images.shca-medication-images.workers.dev',
    ),
  });

  final String baseUrl;

  Future<EmergencyPushResult> send(String alertId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const EmergencyPushResult(
        accepted: 0,
        unavailable: 0,
        linkedCaregivers: 0,
        message: 'Sign in is required for caregiver push.',
      );
    }
    final token = await user.getIdToken();
    if (token == null || token.isEmpty) {
      return const EmergencyPushResult(
        accepted: 0,
        unavailable: 0,
        linkedCaregivers: 0,
        message: 'A secure notification token could not be created.',
      );
    }
    try {
      final endpoint = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
      final response = await http
          .post(
            Uri.parse('$endpoint/v1/emergency-alerts/push'),
            headers: <String, String>{
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(<String, String>{'alertId': alertId}),
          )
          .timeout(const Duration(seconds: 20));
      final decoded = _decode(response.body);
      return EmergencyPushResult.fromJson(decoded ?? const {});
    } catch (_) {
      return const EmergencyPushResult(
        accepted: 0,
        unavailable: 1,
        linkedCaregivers: 0,
        message: 'Caregiver push could not be reached.',
      );
    }
  }

  Map<String, dynamic>? _decode(String body) {
    try {
      final value = jsonDecode(body);
      return value is Map<String, dynamic> ? value : null;
    } catch (_) {
      return null;
    }
  }
}
