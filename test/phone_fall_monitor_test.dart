import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shca/screens/auth/elderly_home.dart';
import 'package:shca/services/activity_recognition_service.dart';
import 'package:shca/services/phone_fall_monitor.dart';
import 'package:shca/services/wearable_bridge_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = PhoneFallMonitor.methods;
  const eventControl = MethodChannel('com.shca.shca/phone_monitoring_events');
  final calls = <MethodCall>[];
  var enabled = false;
  var pending = false;
  Map<String, dynamic> state() => {
    'enabled': enabled,
    'state': enabled ? 'active' : 'stopped',
    'label': enabled ? 'walking' : 'Fall detection off',
    'message': enabled
        ? 'Background monitoring is active.'
        : 'Fall detection is off.',
    'confidence': enabled ? 0.9 : 0.0,
    'possibleFall': pending,
    if (pending) 'pendingFallId': 'existing-background-fall',
    if (pending)
      'fallDeadline': DateTime.now()
          .add(const Duration(seconds: 30))
          .millisecondsSinceEpoch,
  };
  setUp(() {
    enabled = false;
    pending = false;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(eventControl, (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
          calls.add(call);
          if (call.method == 'getAlarmDisplayAccess') {
            return {'appearOnTop': true, 'fullScreen': true};
          }
          if (call.method == 'setEnabled') {
            enabled = (call.arguments as Map)['enabled'] == true;
          }
          if (call.method == 'respondToFall') pending = false;
          return call.method == 'respondToFall' ? null : state();
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(eventControl, null);
  });

  test(
    'attaching respects Off, and disposing the UI leaves monitoring on',
    () async {
      final monitor = PhoneFallMonitor();
      await monitor.start();
      expect(monitor.enabled, isFalse);
      expect(monitor.snapshot.state, ActivityMonitorState.stopped);
      await monitor.setEnabled(true);
      expect(monitor.enabled, isTrue);
      monitor.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(enabled, isTrue);
      expect(calls.where((call) => call.method == 'setEnabled'), hasLength(1));

      final reopened = PhoneFallMonitor();
      await reopened.start();
      expect(reopened.enabled, isTrue);
      expect(reopened.snapshot.label, 'walking');
      await reopened.stop();
      expect(reopened.enabled, isFalse);
      reopened.dispose();
    },
  );

  test('a fall response addresses the existing background event', () async {
    final monitor = PhoneFallMonitor();
    await monitor.respondToFall(eventId: 'fall-existing', send: false);
    expect(calls.single.method, 'respondToFall');
    expect(calls.single.arguments, {'eventId': 'fall-existing', 'send': false});
    monitor.dispose();
  });

  test('alarm access is granted before background detection starts', () async {
    final order = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methods, (call) async {
      order.add(call.method);
      if (call.method == 'getAlarmDisplayAccess') {
        return {'appearOnTop': false, 'fullScreen': false};
      }
      enabled = true;
      return state();
    });
    messenger.setMockMethodCallHandler(PhoneFallMonitor.alarmPermissions, (
      call,
    ) async {
      order.add(call.method);
      return true;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        PhoneFallMonitor.alarmPermissions,
        null,
      ),
    );
    final monitor = PhoneFallMonitor();
    await monitor.setEnabled(true);
    expect(order, [
      'getAlarmDisplayAccess',
      'requestAppearOnTopPermission',
      'requestFullScreenPermission',
      'setEnabled',
    ]);
    expect(monitor.enabled, isTrue);
    monitor.dispose();
  });

  test(
    'denied overlay access does not start notification-only detection',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        return {'appearOnTop': false, 'fullScreen': true};
      });
      messenger.setMockMethodCallHandler(
        PhoneFallMonitor.alarmPermissions,
        (_) async => false,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          PhoneFallMonitor.alarmPermissions,
          null,
        ),
      );
      final monitor = PhoneFallMonitor();
      await expectLater(
        monitor.setEnabled(true),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'overlay-required',
          ),
        ),
      );
      expect(calls.where((call) => call.method == 'setEnabled'), isEmpty);
      expect(monitor.enabled, isFalse);
      monitor.dispose();
    },
  );

  testWidgets('phone button controls the service and survives leaving home', (
    tester,
  ) async {
    final monitor = PhoneFallMonitor();
    await tester.pumpWidget(
      MaterialApp(
        home: ElderlyHomeScreen(
          activityMonitor: monitor,
          loadRemoteProfile: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Turn on fall detection'), findsOneWidget);
    await tester.tap(find.byKey(const Key('phone-fall-detection-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Turn off fall detection'), findsOneWidget);
    await tester.tap(find.byKey(const Key('phone-fall-detection-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Turn on fall detection'), findsOneWidget);
    await tester.tap(find.byKey(const Key('phone-fall-detection-toggle')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    expect(enabled, isTrue);
    monitor.dispose();
  });

  test('a fresh disabled watch is shown as off', () {
    expect(
      WearableStatus(
        connected: true,
        label: 'Fall detection off',
        updatedAt: DateTime.now(),
      ).monitoringActive,
      isFalse,
    );
  });

  testWidgets(
    'Android fall confirmation stays in its native full-screen window',
    (tester) async {
      enabled = true;
      pending = true;
      final monitor = PhoneFallMonitor();
      await tester.pumpWidget(
        MaterialApp(
          home: ElderlyHomeScreen(
            activityMonitor: monitor,
            loadRemoteProfile: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(monitor.snapshot.possibleFall, isTrue);
      expect(find.text('Are you safe?'), findsNothing);
      expect(find.byKey(const Key('fall-im-safe')), findsNothing);
      expect(calls.where((call) => call.method == 'respondToFall'), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      monitor.dispose();
    },
  );
}
