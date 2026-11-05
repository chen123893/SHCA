import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shca/services/emergency_location_service.dart';
import 'package:shca/widgets/alert_location_card.dart';
import 'package:shca/widgets/emergency_location_settings.dart';

void main() {
  final location = <String, dynamic>{
    'latitude': 3.139,
    'longitude': 101.6869,
    'recordedAt': 1700000000000,
    'accuracyMeters': 35,
    'source': 'watch',
    'kind': 'last_known',
  };
  test(
    'historical snapshots remain readable and Maps uses only coordinates',
    () {
      final saved = AlertLocation.parse(location)!;
      expect(saved.lastKnown, isTrue);
      expect(saved.source, 'watch');
      expect(saved.mapsUri.host, 'www.google.com');
      expect(saved.mapsUri.queryParameters['query'], '3.139,101.6869');
      expect(AlertLocation.parse(null), isNull);
      for (final change in [
        {'latitude': double.nan},
        {'longitude': 181},
        {'accuracyMeters': -1},
        {'recordedAt': double.infinity},
        {'recordedAt': 1700000000000.5},
        {'source': 'other'},
        {'kind': 'live'},
      ]) {
        expect(AlertLocation.parse({...location, ...change}), isNull);
      }
    },
  );
  testWidgets(
    'old alerts render safely and valid snapshots show Maps and age',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: AlertLocationCard(location: null)),
        ),
      );
      expect(find.text('Location unavailable for this alert.'), findsOneWidget);
      expect(find.text('Open in Maps'), findsNothing);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AlertLocationCard(location: location)),
        ),
      );
      expect(find.text('Last known location'), findsOneWidget);
      expect(find.textContaining('From the watch'), findsOneWidget);
      expect(find.text('Accuracy about 35 m'), findsOneWidget);
      expect(find.text('Open in Maps'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('sharing stays off after device permission is denied', (
    tester,
  ) async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(EmergencyLocationService.channel, (
          call,
        ) async {
          calls.add(call.method);
          return {'enabled': false, 'backgroundAllowed': false};
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(EmergencyLocationService.channel, null),
    );
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: EmergencyLocationSettings())),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const Key('emergency-location-toggle')),
          )
          .value,
      isFalse,
    );
    await tester.tap(find.byKey(const Key('emergency-location-toggle')));
    await tester.pumpAndSettle();
    expect(calls, ['status', 'setEnabled']);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const Key('emergency-location-toggle')),
          )
          .value,
      isFalse,
    );
    expect(find.textContaining('Allow location permission'), findsOneWidget);
    expect(calls.contains('capture'), isFalse);
  });
  test(
    'permission failure allows emergency flow to continue without location',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            EmergencyLocationService.channel,
            (_) async => throw PlatformException(code: 'denied'),
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(EmergencyLocationService.channel, null),
      );
      expect(await EmergencyLocationService.capture(), isNull);
    },
  );
}
