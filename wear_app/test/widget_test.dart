import 'package:flutter_test/flutter_test.dart';
import 'package:shca_watch/main.dart';
import 'package:shca_watch/services/wear_motion_service.dart';

void main() {
  test('normal sitting movement does not pass the wrist impact gate', () {
    final evidence = evaluateWristImpact(
      accelerationMagnitudes: const [9.8, 10.4, 12.3, 14.2, 9.5],
      angularSpeedMagnitudes: const [0.1, 0.5, 1.1, 1.8, 0.4],
    );

    expect(
      evidence.passes(
        minimumPeakAcceleration: 18,
        minimumAccelerationRange: 12,
        minimumPeakJerk: 350,
        minimumPeakAngularSpeed: 2.5,
      ),
      isFalse,
    );
  });

  test('a sharp rotating wrist impact passes the physical gate', () {
    final evidence = evaluateWristImpact(
      accelerationMagnitudes: const [9.8, 4.0, 7.0, 24.0, 10.0],
      angularSpeedMagnitudes: const [0.2, 1.0, 2.0, 4.5, 0.8],
    );

    expect(
      evidence.passes(
        minimumPeakAcceleration: 18,
        minimumAccelerationRange: 12,
        minimumPeakJerk: 350,
        minimumPeakAngularSpeed: 2.5,
      ),
      isTrue,
    );
  });

  testWidgets('watch home keeps the elderly-focused emergency interface', (
    tester,
  ) async {
    await tester.pumpWidget(const ShcaWatchApp(enableServices: false));
    await tester.pump();

    expect(find.text('SHCA'), findsOneWidget);
    expect(find.text('Medicine'), findsOneWidget);
    expect(find.text('SOS'), findsOneWidget);
  });
}
