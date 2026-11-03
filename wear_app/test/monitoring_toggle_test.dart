import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shca_watch/main.dart';
import 'package:shca_watch/services/watch_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('com.shca.shca/watch_bridge');
  const events = MethodChannel('com.shca.shca/watch_events');

  test('missing monitoring setting preserves existing watch behavior', () {
    expect(
      WatchInitialState.fromMap({'signedIn': true}).monitoringEnabled,
      isTrue,
    );
    expect(
      WatchInitialState.fromMap({'monitoringEnabled': false}).monitoringEnabled,
      isFalse,
    );
  });

  testWidgets('disabled watch stays off after background and resume', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(225, 225);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      events,
      (_) async => null,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(methods, (
      call,
    ) async {
      calls.add(call);
      return switch (call.method) {
        'getInitialState' => {'signedIn': true, 'monitoringEnabled': false},
        _ => null,
      };
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        events,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        methods,
        null,
      );
    });
    await tester.pumpWidget(const ShcaWatchApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('activity-shortcut')));
    await tester.pumpAndSettle();
    expect(find.text('Turn on fall detection'), findsOneWidget);
    expect(find.text('Fall detection off'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Fall detection off'), findsOneWidget);
    expect(
      calls.where((call) => call.method == 'setMonitoringEnabled'),
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
