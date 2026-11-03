import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shca/widgets/emergency_information_dialog.dart';

Future<void> showEmergencyInfo(
  WidgetTester tester, {
  String medicalCondition = 'Diabetes; high blood pressure',
  String phone = '012 345 6789',
  Future<bool> Function()? onCall,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => EmergencyInformationDialog(
                personName: 'Goh Lay Hong',
                medicalCondition: medicalCondition,
                emergencyPhone: phone,
                onCall: onCall,
                deliveryTitle: 'Caregiver alert submitted',
                deliveryMessage: 'Push: accepted. Email: accepted.',
              ),
            ),
            child: const Text('Open SOS'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open SOS'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'bystanders see saved conditions and contact before delivery details',
    (tester) async {
      var calls = 0;
      await showEmergencyInfo(
        tester,
        onCall: () async {
          calls++;
          return true;
        },
      );
      expect(find.text('Goh Lay Hong'), findsOneWidget);
      expect(find.text('Diabetes; high blood pressure'), findsOneWidget);
      expect(find.text('012 345 6789'), findsOneWidget);
      expect(find.text('Push: accepted. Email: accepted.'), findsNothing);
      await tester.ensureVisible(
        find.byKey(const Key('emergency-contact-call')),
      );
      await tester.tap(find.byKey(const Key('emergency-contact-call')));
      await tester.pumpAndSettle();
      expect(calls, 1);
      await tester.ensureVisible(find.text('Caregiver notification status'));
      await tester.tap(find.text('Caregiver notification status'));
      await tester.pumpAndSettle();
      expect(find.text('Push: accepted. Email: accepted.'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Emergency information'), findsNothing);
    },
  );

  testWidgets(
    'missing details do not imply no medical conditions or offer an empty call',
    (tester) async {
      await showEmergencyInfo(tester, medicalCondition: ' ', phone: ' ');
      expect(find.text('Not provided in the saved profile'), findsOneWidget);
      expect(find.text('No number saved'), findsOneWidget);
      expect(find.byKey(const Key('emergency-contact-call')), findsNothing);
    },
  );

  testWidgets(
    'large text remains scrollable and dialler failure stays visible in dialog',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await showEmergencyInfo(
        tester,
        medicalCondition:
            'Diabetes; high blood pressure. Additional saved profile notes that wrap over several lines.',
        textScale: 1.6,
        onCall: () async => throw StateError('No dialler'),
      );
      expect(tester.takeException(), isNull);
      final call = find.byKey(const Key('emergency-contact-call'));
      await tester.ensureVisible(call);
      await tester.tap(call);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Call the number above using another phone'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Close'), findsOneWidget);
    },
  );
}
