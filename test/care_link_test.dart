import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shca/screens/auth/link_elderly.dart';
import 'package:shca/services/care_link_service.dart';

class _FakeCareLinkRepository implements CareLinkRepository {
  int linkCalls = 0;

  @override
  Future<String> ensurePairingCode(String elderlyId) async => 'ABC234';

  @override
  Future<LinkedElderly> linkElderly({
    required String caregiverId,
    required String codeOrEmail,
    required String relationship,
  }) async {
    linkCalls++;
    return LinkedElderly(
      id: 'elderly-1',
      fullName: 'George Wong',
      email: 'george@example.com',
      emergencyPhone: '012-345 6789',
      relationship: relationship,
    );
  }

  @override
  Future<List<LinkedElderly>> loadLinkedElderly(String caregiverId) async =>
      const <LinkedElderly>[];

  @override
  Future<List<String>> loadLinkedCaregiverIds(String elderlyId) async =>
      const <String>[];

  @override
  Future<void> unlinkElderly({
    required String caregiverId,
    required String elderlyId,
  }) async {}
}

void main() {
  test('pairing code generator omits ambiguous characters', () {
    for (var index = 0; index < 100; index++) {
      final code = generatePairingCode();
      expect(code, hasLength(6));
      expect(code, matches(RegExp(r'^[A-HJ-NP-Z2-9]{6}$')));
    }
  });

  test('care link input normalization handles email and spaced code', () {
    expect(
      normaliseCareLinkInput('  George@Example.COM '),
      'george@example.com',
    );
    expect(normalisePairingCode(' ab-c 234 '), 'ABC234');
    expect(careLinkCodeLookupId(' ab-c 234 '), 'code_ABC234');
    expect(
      careLinkEmailLookupId(' George@Example.COM '),
      careLinkEmailLookupId('george@example.com'),
    );
  });

  test('Malaysian local and international phone formats compare equally', () {
    expect(isSamePhoneNumber('012-345 6789', '+60 12-345 6789'), isTrue);
    expect(isSamePhoneNumber('012-345 6789', '011-222 3333'), isFalse);
    expect(isSamePhoneNumber('', ''), isFalse);
  });

  testWidgets('elderly completion screen shows private link information', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ElderlyLinkReadyScreen(
          fullName: 'George Wong',
          email: 'george@example.com',
          pairingCode: 'ABC234',
          emergencyPhone: '012-345 6789',
        ),
      ),
    );

    expect(find.text('Your account is ready'), findsOneWidget);
    expect(find.text('ABC234'), findsOneWidget);
    expect(find.text('george@example.com'), findsOneWidget);
    expect(find.text('012-345 6789'), findsOneWidget);
    expect(find.textContaining('Only share the code'), findsOneWidget);
  });

  testWidgets('caregiver sees emergency contact only after a successful link', (
    tester,
  ) async {
    final repository = _FakeCareLinkRepository();
    await tester.pumpWidget(
      MaterialApp(
        routes: <String, WidgetBuilder>{
          '/home': (_) => const Scaffold(body: Text('Caregiver home')),
        },
        home: LinkElderlyScreen(
          repository: repository,
          caregiverId: 'caregiver-1',
        ),
      ),
    );

    expect(find.text('012-345 6789'), findsNothing);
    await tester.enterText(
      find.byKey(const Key('elderly-link-input')),
      'ABC234',
    );
    await tester.enterText(
      find.byKey(const Key('caregiver-relationship-input')),
      'Daughter',
    );
    await tester.ensureVisible(find.byKey(const Key('link-elderly-button')));
    await tester.tap(find.byKey(const Key('link-elderly-button')));
    await tester.pumpAndSettle();

    expect(repository.linkCalls, 1);
    expect(find.text('Elderly Account Linked'), findsOneWidget);
    expect(find.text('George Wong'), findsOneWidget);
    expect(find.text('012-345 6789'), findsOneWidget);
    expect(find.text('Daughter'), findsOneWidget);
  });

  testWidgets('invalid short code is rejected before repository access', (
    tester,
  ) async {
    final repository = _FakeCareLinkRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: LinkElderlyScreen(
          repository: repository,
          caregiverId: 'caregiver-1',
          initialRelationship: 'Daughter',
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('elderly-link-input')), 'A12');
    await tester.ensureVisible(find.byKey(const Key('link-elderly-button')));
    await tester.tap(find.byKey(const Key('link-elderly-button')));
    await tester.pump();

    expect(repository.linkCalls, 0);
    expect(
      find.text('The elderly link code contains six characters.'),
      findsOneWidget,
    );
  });
}
