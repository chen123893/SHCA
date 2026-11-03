import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shca/screens/auth/elderly_home.dart';
import 'package:shca/screens/auth/elderly_monitoring.dart';
import 'package:shca/services/activity_recognition_service.dart';
import 'package:shca/services/wearable_bridge_service.dart';

class _FakeActivityMonitor extends ChangeNotifier implements ActivityMonitor {
  bool started = false;

  @override
  ActivitySnapshot snapshot = ActivitySnapshot(
    label: 'walking',
    confidence: 0.93,
    fallProbability: 0.02,
    updatedAt: DateTime(2026, 8, 23, 8, 30),
    state: ActivityMonitorState.active,
    message: 'On-device monitoring is active.',
  );

  @override
  Future<void> start() async => started = true;

  @override
  Future<void> stop() async => started = false;

  @override
  void acknowledgePossibleFall() {
    snapshot = ActivitySnapshot(
      label: snapshot.label,
      confidence: snapshot.confidence,
      fallProbability: snapshot.fallProbability,
      updatedAt: snapshot.updatedAt,
      state: snapshot.state,
      message: 'Safety confirmed. Monitoring continues.',
    );
    notifyListeners();
  }
}

void main() {
  testWidgets('phone fall countdown automatically requests an alert', (
    tester,
  ) async {
    const vibrationChannel = MethodChannel('com.shca.shca/wearable');
    final vibrationCalls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(vibrationChannel, (call) async {
          vibrationCalls.add(call.method);
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(vibrationChannel, null),
    );
    FallSafetyResponse? response;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              response = await showDialog<FallSafetyResponse>(
                context: context,
                barrierDismissible: false,
                builder: (_) => const PossibleFallCountdownDialog(
                  countdownDuration: Duration(seconds: 3),
                ),
              );
            },
            child: const Text('Detect fall'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Detect fall'));
    await tester.pump();
    expect(find.text('Are you safe?'), findsOneWidget);
    expect(vibrationCalls, contains('startFallAlert'));
    expect(find.text('3'), findsOneWidget);
    expect(find.textContaining('automatically notify'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('2'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('1'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.text('Are you safe?'), findsNothing);
    expect(response, FallSafetyResponse.sendAlert);
    expect(vibrationCalls, contains('stopFallAlert'));
  });

  testWidgets("I'm safe cancels the phone fall countdown", (tester) async {
    FallSafetyResponse? response;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              response = await showDialog<FallSafetyResponse>(
                context: context,
                barrierDismissible: false,
                builder: (_) => const PossibleFallCountdownDialog(),
              );
            },
            child: const Text('Detect fall'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Detect fall'));
    await tester.pump();
    expect(find.text('30'), findsOneWidget);
    await tester.tap(find.byKey(const Key('fall-im-safe')));
    await tester.pumpAndSettle();

    expect(response, FallSafetyResponse.safe);
    expect(find.text('Are you safe?'), findsNothing);
  });

  for (final action in ['safe', 'send', 'dispose']) {
    testWidgets('fall sound and vibration stop on $action', (tester) async {
      const channel = MethodChannel('com.shca.shca/wearable');
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return true;
      });
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      });
      FallSafetyResponse? response;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                response = await showDialog<FallSafetyResponse>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => const PossibleFallCountdownDialog(),
                );
              },
              child: const Text('Detect fall'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Detect fall'));
      await tester.pumpAndSettle();
      final start = calls.singleWhere(
        (call) => call.method == 'startFallAlert',
      );
      expect((start.arguments as Map)['durationMillis'], 30000);
      if (action == 'dispose') {
        await tester.pumpWidget(const SizedBox());
      } else {
        await tester.tap(
          find.byKey(Key(action == 'safe' ? 'fall-im-safe' : 'fall-send-now')),
        );
      }
      await tester.pumpAndSettle();
      expect(calls.any((call) => call.method == 'stopFallAlert'), isTrue);
      expect(find.text('Are you safe?'), findsNothing);
      await tester.pump(const Duration(seconds: 31));
      if (action == 'safe') expect(response, FallSafetyResponse.safe);
      if (action == 'send') expect(response, FallSafetyResponse.sendAlert);
      if (action == 'dispose') expect(response, isNull);
      expect(
        calls.where((call) => call.method == 'startFallAlert'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    });
  }

  test('wearable is active only when the SHCA watch is linked and fresh', () {
    final now = DateTime.now();
    expect(
      WearableStatus(
        connected: false,
        label: 'Walking',
        updatedAt: now,
      ).monitoringActive,
      isFalse,
    );
    expect(
      WearableStatus(
        connected: true,
        label: 'Walking',
        updatedAt: now.subtract(const Duration(minutes: 1)),
      ).monitoringActive,
      isFalse,
    );
    expect(
      WearableStatus(
        connected: true,
        label: 'Walking',
        updatedAt: now,
      ).monitoringActive,
      isTrue,
    );
  });
  test('vehicle transition is never selected for the home activity card', () {
    final decision = selectPrimaryActivity(
      labels: const [
        'standing',
        'walking',
        'running',
        'jumping',
        'chair_transition',
        'vehicle_transition',
        'fall',
      ],
      probabilities: const [0.03, 0.08, 0.01, 0.01, 0.04, 0.81, 0.02],
      fallIndex: 6,
      fallProbability: 0.02,
      fallThreshold: 0.41,
    );

    expect(decision.label, 'activity_unknown');
  });

  test('a confident walking result remains walking', () {
    final decision = selectPrimaryActivity(
      labels: const [
        'standing',
        'walking',
        'running',
        'jumping',
        'chair_transition',
        'vehicle_transition',
        'fall',
      ],
      probabilities: const [0.04, 0.86, 0.03, 0.01, 0.02, 0.03, 0.01],
      fallIndex: 6,
      fallProbability: 0.01,
      fallThreshold: 0.41,
    );

    expect(decision.label, 'walking');
    expect(decision.confidence, closeTo(0.86, 0.0001));
  });

  test('binary fall output alone does not override confident exercise', () {
    final decision = selectPrimaryActivity(
      labels: const ['resting', 'walking', 'running', 'active', 'fall'],
      probabilities: const [0.01, 0.02, 0.05, 0.84, 0.08],
      fallIndex: 4,
      fallProbability: 0.91,
      fallThreshold: 0.65,
    );

    expect(decision.label, 'active');
    expect(decision.confidence, closeTo(0.84, 0.0001));
  });

  test('fall is displayed when both model outputs strongly agree', () {
    final decision = selectPrimaryActivity(
      labels: const ['resting', 'walking', 'running', 'active', 'fall'],
      probabilities: const [0.01, 0.01, 0.01, 0.07, 0.90],
      fallIndex: 4,
      fallProbability: 0.88,
      fallThreshold: 0.65,
    );

    expect(decision.label, 'fall');
    expect(decision.confidence, closeTo(0.88, 0.0001));
  });

  testWidgets('elderly dashboard displays live model activity', (tester) async {
    final monitor = _FakeActivityMonitor();

    await tester.pumpWidget(
      MaterialApp(
        home: ElderlyHomeScreen(
          activityMonitor: monitor,
          loadRemoteProfile: false,
          initialName: 'George Wong',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Elderly Dashboard'), findsOneWidget);
    expect(find.textContaining('George Wong'), findsOneWidget);
    expect(find.text('Walking'), findsOneWidget);
    expect(find.textContaining('93% confidence'), findsOneWidget);
    expect(find.text('SOS'), findsOneWidget);
    expect(find.text('Medication Reminders'), findsOneWidget);
    expect(monitor.started, isTrue);
  });

  testWidgets('activity card changes when model output changes', (
    tester,
  ) async {
    final monitor = _FakeActivityMonitor();
    await tester.pumpWidget(
      MaterialApp(
        home: ElderlyHomeScreen(
          activityMonitor: monitor,
          loadRemoteProfile: false,
        ),
      ),
    );

    monitor.snapshot = ActivitySnapshot(
      label: 'running',
      confidence: 0.88,
      fallProbability: 0.03,
      updatedAt: DateTime(2026, 8, 23, 9),
      state: ActivityMonitorState.active,
      message: 'On-device monitoring is active.',
    );
    monitor.notifyListeners();
    await tester.pump();

    expect(find.text('Running'), findsOneWidget);
    expect(find.textContaining('88% confidence'), findsOneWidget);

    monitor.snapshot = ActivitySnapshot(
      label: 'resting',
      confidence: 0.96,
      fallProbability: 0.01,
      updatedAt: DateTime(2026, 8, 23, 9, 1),
      state: ActivityMonitorState.active,
      message: 'On-device monitoring is active.',
    );
    monitor.notifyListeners();
    await tester.pump();

    expect(find.text('Resting'), findsOneWidget);
    expect(find.textContaining('96% confidence'), findsOneWidget);
  });

  testWidgets('monitoring page keeps phone and watch activity separate', (
    tester,
  ) async {
    final monitor = _FakeActivityMonitor();
    await tester.pumpWidget(
      MaterialApp(home: ElderlyMonitoringScreen(activityMonitor: monitor)),
    );
    await tester.pump();

    expect(find.text('Monitoring Status'), findsWidgets);
    expect(find.text('Phone Motion Sensors'), findsOneWidget);
    expect(find.text('Watch Motion Sensors'), findsOneWidget);
    expect(find.text('Activity by Device'), findsOneWidget);
    expect(find.text('PHONE'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('WATCH'), 180);
    expect(find.text('WATCH'), findsOneWidget);
    expect(find.text('Walking'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Auto Fall Detection Active'),
      220,
    );
    expect(find.text('Auto Fall Detection Active'), findsOneWidget);
    expect(find.text('Connected'), findsNothing);
    expect(find.byKey(const Key('view-fall-history')), findsOneWidget);
    expect(monitor.started, isTrue);
  });
}
