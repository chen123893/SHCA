import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shca_watch/main.dart';
import 'package:shca_watch/services/watch_bridge.dart';
import 'package:shca_watch/services/wrist_fall_confirmation.dart';

void main() {
  const features = [
    'acc_x_m_s2',
    'acc_y_m_s2',
    'acc_z_m_s2',
    'gyro_x_rad_s',
    'gyro_y_rad_s',
    'gyro_z_rad_s',
    'acc_magnitude_m_s2',
    'gyro_magnitude_rad_s',
  ];
  List<List<double>> sequence({
    bool postureChange = false,
    bool unloading = false,
    bool exercise = false,
    bool settled = true,
  }) => List.generate(200, (i) {
    final impact = i == 75 || (exercise && (i == 110 || i == 135));
    final free = unloading && i >= 65 && i <= 71;
    final acc = impact
        ? 25.0
        : free
        ? 3.0
        : 9.81;
    final changed = postureChange && i >= 90;
    final gyro = impact || (!settled && i > 90) ? 4.0 : .1;
    return [
      changed ? acc : 0.0,
      0.0,
      changed ? 0.0 : acc,
      gyro,
      0.0,
      0.0,
      acc,
      gyro,
    ];
  });
  test(
    'isolated wrist flick with no changed posture does not confirm a fall',
    () {
      expect(confirmsWristFall(sequence(), features), isFalse);
    },
  );
  test('continued exercise is rejected even if the wrist later settles', () {
    expect(
      confirmsWristFall(
        sequence(exercise: true, postureChange: true),
        features,
      ),
      isFalse,
    );
  });
  test('impact with changed resting orientation and settling is eligible', () {
    expect(confirmsWristFall(sequence(postureChange: true), features), isTrue);
  });
  test(
    'sustained unloading and impact can confirm without changed orientation',
    () {
      expect(confirmsWristFall(sequence(unloading: true), features), isTrue);
    },
  );
  test('impact followed by continued movement is not confirmed', () {
    expect(
      confirmsWristFall(
        sequence(postureChange: true, settled: false),
        features,
      ),
      isFalse,
    );
  });
  test(
    'Today list excludes yesterday, tomorrow, taken and already due doses',
    () {
      final now = DateTime(2026, 9, 9, 10);
      WatchMedication dose(int day, int hour, {String status = 'pending'}) =>
          WatchMedication(
            id: '$day-$hour',
            occurrenceId: '$day-$hour',
            scheduledAt: DateTime(2026, 9, day, hour),
            remindAt: DateTime(2026, 9, day, hour),
            status: status,
          );
      final results = upcomingToday([
        dose(8, 20),
        dose(10, 8),
        dose(9, 9),
        dose(9, 11, status: 'taken'),
        dose(9, 12),
      ], now);
      expect(results.map((e) => e.id), ['9-12']);
    },
  );
  for (final size in [
    const Size(192, 192),
    const Size(225, 225),
    const Size(240, 240),
  ]) {
    testWidgets('SOS and medicine Back are usable on $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const ShcaWatchApp(enableServices: false));
      expect(tester.takeException(), isNull);
      final sos = tester.getRect(find.byKey(const Key('home-sos')));
      expect(
        (sos.center - Offset(size.width / 2, size.height / 2)).distance,
        lessThan(1),
      );
      await tester.tap(find.byKey(const Key('medicine-shortcut')));
      await tester.pump();
      expect(find.text('Today’s medicine'), findsOneWidget);
      expect(find.text('No upcoming doses today.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('watch-back')));
      await tester.pump();
      expect(find.byKey(const Key('home-sos')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('home-sos')));
      await tester.pump();
      expect(find.text('Emergency SOS'), findsOneWidget);
      await tester.tap(find.byKey(const Key('watch-back')));
      await tester.pump();
      expect(find.byKey(const Key('home-sos')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
