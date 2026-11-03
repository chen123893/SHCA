import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shca_watch/main.dart';

void main() {
  const methods = MethodChannel('com.shca.shca/watch_bridge');
  const events = MethodChannel('com.shca.shca/watch_events');
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(events, (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
          calls.add(call);
          return switch (call.method) {
            'getInitialState' => <String, dynamic>{'signedIn': false},
            'startPhoneSignIn' => {
              'code': '083079',
              'expiresAt': DateTime.now()
                  .add(const Duration(minutes: 5))
                  .millisecondsSinceEpoch,
            },
            'editCredential' =>
              (call.arguments as Map)['field'] == 'email'
                  ? 'elderly@example.test'
                  : 'demo-password',
            'signIn' => {'error': 'Demo sign-in refused'},
            _ => true,
          };
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(events, null);
  });

  testWidgets('watch opens code sign-in first and retains a manual fallback', (
    tester,
  ) async {
    await tester.pumpWidget(const ShcaWatchApp());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('watch-email')), findsNothing);
    await tester.tap(find.byKey(const Key('watch-connect-phone')));
    await tester.pumpAndSettle();
    expect(find.text('083079'), findsOneWidget);
    expect(find.textContaining('Profile → Connect smartwatch'), findsOneWidget);
    await tester.tap(find.text('Use email instead'));
    await tester.pumpAndSettle();
    expect(calls.any((call) => call.method == 'cancelPhoneSignIn'), isTrue);
    expect(find.byKey(const Key('watch-email')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'native email and password edits are synchronized before sign-in',
    (tester) async {
      await tester.pumpWidget(const ShcaWatchApp());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('watch-use-email')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('watch-email')));
      await tester.pumpAndSettle();
      final email = tester.widget<TextField>(
        find.byKey(const Key('watch-email')),
      );
      expect(email.controller!.text, 'elderly@example.test');
      expect(email.readOnly, isTrue);
      await tester.tap(find.byKey(const Key('watch-password')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('watch-password')))
            .obscureText,
        isTrue,
      );
      await tester.tap(find.byKey(const Key('watch-sign-in')));
      await tester.pumpAndSettle();
      final sent =
          calls.singleWhere((call) => call.method == 'signIn').arguments as Map;
      expect(sent['email'], 'elderly@example.test');
      expect(sent['password'], 'demo-password');
      expect(find.text('Demo sign-in refused'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
