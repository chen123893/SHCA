import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shca/models/health_statistics.dart';
import 'package:shca/services/gemini_statistics_service.dart';

void main() {
  HealthStatistics history() => HealthStatistics.calculate(
    now: DateTime(2026, 10, 11, 18),
    periodDays: 7,
    doses: [
      for (var day = 5; day <= 11; day++)
        StatisticsDose(
          key: 'dose-$day',
          scheduledAt: DateTime(2026, 10, day, 8),
          status: day <= 9
              ? 'taken'
              : day == 10
              ? 'missed'
              : 'snoozed',
        ),
    ],
    falls: [
      StatisticsFall(
        detectedAt: DateTime(2026, 10, 9, 9),
        status: 'alert_sent',
      ),
    ],
  );

  test('sends aggregate history and parses the AI forecast', () async {
    late Map<String, dynamic> sent;
    final service = AiStatisticsService(
      baseUrl: 'https://worker.test',
      tokenProvider: () async => 'token',
      client: MockClient((request) async {
        expect(request.url.path, '/v1/statistics/forecast');
        expect(request.headers['authorization'], 'Bearer token');
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'forecast': {
              'summary': 'Completion may remain stable.',
              'predictedCompletion': 76,
              'completionLower': 58,
              'completionUpper': 89,
              'trend': 'stable',
              'possibleFallAlertLevel': 'moderate',
              'actions': ['Review unresolved records.'],
              'limitations': 'The history is short.',
            },
            'model': 'openai/gpt-oss-20b',
            'generatedAt': '2026-10-11T10:00:00.000Z',
            'cached': false,
          }),
          200,
        );
      }),
    );

    final result = await service.generate(
      elderlyId: 'elderly-account',
      statistics: history(),
    );
    expect(result.predictedCompletion, 76);
    expect(result.actions, ['Review unresolved records.']);
    expect(sent['elderlyId'], 'elderly-account');
    expect((sent['days'] as List), hasLength(7));
    expect(jsonEncode(sent), isNot(contains('medicineName')));
  });

  test('does not call AI service when history is too sparse', () async {
    var called = false;
    final service = AiStatisticsService(
      tokenProvider: () async => 'token',
      client: MockClient((_) async {
        called = true;
        return http.Response('{}', 200);
      }),
    );
    final sparse = HealthStatistics.calculate(
      now: DateTime(2026, 10, 11),
      periodDays: 7,
      doses: [],
      falls: [],
    );
    await expectLater(
      service.generate(elderlyId: 'elderly', statistics: sparse),
      throwsA(isA<StatisticsForecastException>()),
    );
    expect(called, isFalse);
  });
}
