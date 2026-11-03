import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shca/models/health_statistics.dart';
import 'package:shca/screens/auth/caregiver_shared.dart';
import 'package:shca/screens/auth/elderly_shared.dart';
import 'package:shca/screens/auth/knowledge.dart';
import 'package:shca/screens/auth/statistics.dart';
import 'package:shca/services/gemini_statistics_service.dart';

void main() {
  testWidgets('Statistics is available to caregivers, not elderly users', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: CaregiverBottomNavigation(
            selectedIndex: 4,
            onHome: () {},
            onStatus: () {},
            onMedicine: () {},
            onProfile: () {},
            onStatistics: () => tapped = true,
          ),
        ),
      ),
    );
    expect(find.text('Statistics'), findsOneWidget);
    await tester.tap(find.text('Statistics'));
    expect(tapped, isTrue);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: ElderlyBottomNavigation(
            selectedIndex: 0,
            onHome: () {},
            onMonitor: () {},
            onMedicine: () {},
            onProfile: () {},
          ),
        ),
      ),
    );
    expect(find.text('Statistics'), findsNothing);
    expect(find.text('Profile'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('empty dashboard is truthful and renders on a small phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  StatisticsDashboard(
                    statistics: HealthStatistics.calculate(
                      now: DateTime(2026, 9, 21),
                      periodDays: 30,
                      doses: [],
                      falls: [],
                    ),
                  ),
                  const SizedBox(height: 16),
                  SmartInsightsPanel(
                    statistics: HealthStatistics.calculate(
                      now: DateTime(2026, 9, 21),
                      periodDays: 30,
                      doses: [],
                      falls: [],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Your history starts here'), findsOneWidget);
    expect(find.text('Smart Insights'), findsOneWidget);
    expect(find.textContaining('On-device rules'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -2500),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('knowledge topics expand into prevention guidance', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: KnowledgeScreen()));
    await tester.tap(find.text('A safer home'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Keep walkways clear'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI forecast explains its prediction and limitations', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: GeminiForecastPanel(
              forecast: Future.value(
                AiStatisticsForecast(
                  summary: 'The recorded routine may remain stable.',
                  predictedCompletion: 82,
                  completionLower: 68,
                  completionUpper: 91,
                  trend: 'stable',
                  possibleFallAlertLevel: 'low',
                  actions: const ['Check unresolved reminders.'],
                  limitations: 'Only saved records were analysed.',
                  model: 'openai/gpt-oss-20b',
                  generatedAt: DateTime(2026, 10, 11),
                  cached: true,
                ),
              ),
              onRetry: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('AI Forecast'), findsOneWidget);
    expect(find.text('82%'), findsOneWidget);
    expect(find.textContaining('68–91%'), findsOneWidget);
    expect(find.textContaining('not medical advice'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
