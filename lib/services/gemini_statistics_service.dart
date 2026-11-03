import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:shca/models/health_statistics.dart';

class AiStatisticsForecast {
  const AiStatisticsForecast({
    required this.summary,
    required this.predictedCompletion,
    required this.completionLower,
    required this.completionUpper,
    required this.trend,
    required this.possibleFallAlertLevel,
    required this.actions,
    required this.limitations,
    required this.model,
    required this.generatedAt,
    required this.cached,
  });

  final String summary;
  final int predictedCompletion;
  final int completionLower;
  final int completionUpper;
  final String trend;
  final String possibleFallAlertLevel;
  final List<String> actions;
  final String limitations;
  final String model;
  final DateTime generatedAt;
  final bool cached;

  factory AiStatisticsForecast.fromJson(Map<String, dynamic> json) {
    final raw = json['forecast'];
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('Forecast is missing.');
    }
    int requiredInt(String key) {
      final value = raw[key];
      if (value is! num) throw FormatException('$key is missing.');
      return value.round().clamp(0, 100);
    }

    String requiredText(String key) {
      final value = raw[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('$key is missing.');
      }
      return value.trim();
    }

    final actions = raw['actions'];
    if (actions is! List || actions.isEmpty) {
      throw const FormatException('Forecast actions are missing.');
    }
    final generatedAt = DateTime.tryParse(json['generatedAt'] as String? ?? '');
    if (generatedAt == null) {
      throw const FormatException('Forecast time is missing.');
    }
    return AiStatisticsForecast(
      summary: requiredText('summary'),
      predictedCompletion: requiredInt('predictedCompletion'),
      completionLower: requiredInt('completionLower'),
      completionUpper: requiredInt('completionUpper'),
      trend: requiredText('trend'),
      possibleFallAlertLevel: requiredText('possibleFallAlertLevel'),
      actions: [
        for (final action in actions)
          if (action is String && action.trim().isNotEmpty) action.trim(),
      ],
      limitations: requiredText('limitations'),
      model: (json['model'] as String?)?.trim().isNotEmpty == true
          ? (json['model'] as String).trim()
          : 'Groq',
      generatedAt: generatedAt,
      cached: json['cached'] == true,
    );
  }
}

class StatisticsForecastException implements Exception {
  const StatisticsForecastException(this.message);
  final String message;

  @override
  String toString() => message;
}

class AiStatisticsService {
  AiStatisticsService({
    this.baseUrl = const String.fromEnvironment(
      'MEDICATION_IMAGE_API_URL',
      defaultValue:
          'https://shca-medication-images.shca-medication-images.workers.dev',
    ),
    http.Client? client,
    Future<String?> Function()? tokenProvider,
  }) : _client = client ?? http.Client(),
       _tokenProvider = tokenProvider ?? _firebaseToken;

  final String baseUrl;
  final http.Client _client;
  final Future<String?> Function() _tokenProvider;

  Future<AiStatisticsForecast> generate({
    required String elderlyId,
    required HealthStatistics statistics,
  }) async {
    if (statistics.doses < 5 || statistics.recordDays < 3) {
      throw const StatisticsForecastException(
        'AI Forecast needs at least 3 recorded days and 5 dose records. The rule-based outlook remains available.',
      );
    }
    final token = await _tokenProvider();
    if (token == null || token.isEmpty) {
      throw const StatisticsForecastException(
        'Sign in again to generate an AI forecast.',
      );
    }
    try {
      final endpoint = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
      final response = await _client
          .post(
            Uri.parse('$endpoint/v1/statistics/forecast'),
            headers: <String, String>{
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(buildPayload(elderlyId, statistics)),
          )
          .timeout(const Duration(seconds: 30));
      final decoded = _decode(response.body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StatisticsForecastException(
          decoded?['error'] as String? ??
              'The AI service could not create a forecast right now.',
        );
      }
      if (decoded == null) {
        throw const StatisticsForecastException(
          'The AI service returned an unreadable forecast.',
        );
      }
      return AiStatisticsForecast.fromJson(decoded);
    } on StatisticsForecastException {
      rethrow;
    } catch (_) {
      throw const StatisticsForecastException(
        'The AI service could not be reached. The rule-based outlook is still available.',
      );
    }
  }

  static Map<String, dynamic> buildPayload(
    String elderlyId,
    HealthStatistics statistics,
  ) => <String, dynamic>{
    // Used by the SHCA Worker only to authorize the linked caregiver. The
    // Worker removes it before sending the aggregate history to Groq.
    'elderlyId': elderlyId,
    'periodDays': statistics.days.length,
    'asOf': statistics.asOf.toUtc().toIso8601String(),
    'totals': <String, int>{
      'taken': statistics.taken,
      'missed': statistics.missed,
      'unresolved': statistics.unresolved,
      'doses': statistics.doses,
      'possibleFallAlerts': statistics.alerts,
      'recordDays': statistics.recordDays,
    },
    'days': <Map<String, dynamic>>[
      for (final day in statistics.days)
        <String, dynamic>{
          'date': _date(day.date),
          'taken': day.taken,
          'missed': day.missed,
          'unresolved': day.unresolved,
          'possibleFallAlerts': day.alerts,
        },
    ],
    'alertHours': statistics.alertHours,
    'fallStatuses': statistics.fallStatuses,
  };

  static Future<String?> _firebaseToken() async =>
      FirebaseAuth.instance.currentUser?.getIdToken();

  static Map<String, dynamic>? _decode(String body) {
    try {
      final value = jsonDecode(body);
      return value is Map<String, dynamic> ? value : null;
    } catch (_) {
      return null;
    }
  }

  static String _date(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}

// Kept for source compatibility with earlier tests and injected services.
typedef GeminiStatisticsService = AiStatisticsService;
