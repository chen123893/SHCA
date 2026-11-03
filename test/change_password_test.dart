import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shca/screens/auth/change_password.dart';
import 'package:shca/services/password_change_service.dart';

class _FakePasswordChangeService implements PasswordChangeService {
  String? currentPassword;
  String? newPassword;
  Object? error;
  final Completer<void>? pending;

  _FakePasswordChangeService({this.error, this.pending});

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    this.currentPassword = currentPassword;
    this.newPassword = newPassword;
    if (pending != null) await pending!.future;
    if (error case final failure?) throw failure;
  }
}

Widget _screen(PasswordChangeService service) => MaterialApp(
  home: ChangePasswordScreen(
    roleLabel: 'Caregiver',
    accentColor: const Color(0xFFFF8128),
    backgroundColor: const Color(0xFFFFF8F0),
    passwordChangeService: service,
  ),
);

Future<void> _enterValidPasswords(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const Key('current-password')),
    'OldPassword1!',
  );
  await tester.enterText(
    find.byKey(const Key('new-password')),
    'NewPassword2!',
  );
  await tester.enterText(
    find.byKey(const Key('confirm-new-password')),
    'NewPassword2!',
  );
}

void main() {
  testWidgets(
    'valid form verifies the current password and submits the new one',
    (tester) async {
      final service = _FakePasswordChangeService();
      await tester.pumpWidget(_screen(service));
      await _enterValidPasswords(tester);

      await tester.tap(find.byKey(const Key('submit-password-change')));
      await tester.pump();

      expect(service.currentPassword, 'OldPassword1!');
      expect(service.newPassword, 'NewPassword2!');
    },
  );

  testWidgets('form enforces the registration password policy', (tester) async {
    final service = _FakePasswordChangeService();
    await tester.pumpWidget(_screen(service));
    await tester.enterText(
      find.byKey(const Key('current-password')),
      'OldPassword1!',
    );
    await tester.enterText(find.byKey(const Key('new-password')), 'short');
    await tester.enterText(
      find.byKey(const Key('confirm-new-password')),
      'different',
    );

    await tester.tap(find.byKey(const Key('submit-password-change')));
    await tester.pump();

    expect(find.text('Use at least 8 characters.'), findsOneWidget);
    expect(find.text('New passwords do not match.'), findsOneWidget);
    expect(service.currentPassword, isNull);
  });

  testWidgets('authentication failures remain visible on the form', (
    tester,
  ) async {
    final service = _FakePasswordChangeService(
      error: const PasswordChangeFailure('The current password is incorrect.'),
    );
    await tester.pumpWidget(_screen(service));
    await _enterValidPasswords(tester);

    await tester.tap(find.byKey(const Key('submit-password-change')));
    await tester.pumpAndSettle();

    expect(find.text('The current password is incorrect.'), findsOneWidget);
    expect(find.byKey(const Key('password-change-error')), findsOneWidget);
  });

  testWidgets('submit button is disabled while Firebase is updating', (
    tester,
  ) async {
    final pending = Completer<void>();
    final service = _FakePasswordChangeService(pending: pending);
    await tester.pumpWidget(_screen(service));
    await _enterValidPasswords(tester);

    await tester.tap(find.byKey(const Key('submit-password-change')));
    await tester.pump();

    expect(find.text('Updating…'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('submit-password-change')),
    );
    expect(button.onPressed, isNull);

    pending.complete();
    await tester.pump();
  });
}
