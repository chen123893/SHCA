import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shca/screens/auth/connect_watch.dart';

void main() {
  testWidgets('incomplete code never approves a watch', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ConnectWatchScreen(
          accountName: 'David',
          connect: (_) async {
            calls++;
          },
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('watch-connection-code')),
      '123',
    );
    await tester.tap(find.byKey(const Key('approve-watch-sign-in')));
    await tester.pump();
    expect(calls, 0);
    expect(
      find.text('Enter all six digits shown on the watch.'),
      findsOneWidget,
    );
  });
  testWidgets(
    'matching approval uses entered code and shows the intended account',
    (tester) async {
      String? approved;
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectWatchScreen(
            accountName: 'David',
            connect: (code) async {
              approved = code;
            },
          ),
        ),
      );
      expect(find.text('Watch account: David'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('watch-connection-code')),
        '083079',
      );
      await tester.tap(find.byKey(const Key('approve-watch-sign-in')));
      await tester.pumpAndSettle();
      expect(approved, '083079');
      expect(find.text('Watch connected'), findsOneWidget);
      expect(find.textContaining('signed in as David'), findsOneWidget);
    },
  );
  testWidgets(
    'wrong or expired code stays on screen with an actionable error',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectWatchScreen(
            accountName: 'David',
            connect: (_) async {
              throw StateError('No connected watch matches this code.');
            },
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('watch-connection-code')),
        '123456',
      );
      await tester.tap(find.byKey(const Key('approve-watch-sign-in')));
      await tester.pumpAndSettle();
      expect(
        find.text('No connected watch matches this code.'),
        findsOneWidget,
      );
      expect(find.text('Watch connected'), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    },
  );
}
