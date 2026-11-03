import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shca/services/session_service.dart';

void main() {
  test(
    'elderly sign-out stops detection before clearing authentication',
    () async {
      final calls = <String>[];
      final service = AppSessionService(
        clearMedicationAlarms: () async {},
      unregisterCaregiver: () async {},
        stopFallDetection: () async {
          calls.add('stop-monitoring');
        },
        signOut: () async {
          calls.add('sign-out');
        },
      );
      await service.signOut(caregiver: false);
      expect(calls, ['stop-monitoring', 'sign-out']);
    },
  );

  test('notification cleanup failures never block Firebase sign-out', () async {
    var signedOut = false;
    var caregiverUnregistered = false;
    final service = AppSessionService(
      clearMedicationAlarms: () async => throw StateError('cleanup failed'),
      unregisterCaregiver: () async {
        caregiverUnregistered = true;
        throw StateError('unregister failed');
      },
      signOut: () async {
        signedOut = true;
      },
    );

    await service.signOut(caregiver: true);

    expect(caregiverUnregistered, isTrue);
    expect(signedOut, isTrue);
  });

  test('elderly sign-out does not unregister a caregiver token', () async {
    var unregisterCalls = 0;
    var signedOut = false;
    final service = AppSessionService(
      clearMedicationAlarms: () async {},
      unregisterCaregiver: () async {
        unregisterCalls++;
      },
      signOut: () async {
        signedOut = true;
      },
    );

    await service.signOut(caregiver: false);

    expect(unregisterCalls, 0);
    expect(signedOut, isTrue);
  });

  test('cleanup timeout never leaves the Firebase session active', () async {
    var signedOut = false;
    final service = AppSessionService(
      clearMedicationAlarms: () => Completer<void>().future,
      unregisterCaregiver: () async {},
      signOut: () async {
        signedOut = true;
      },
      cleanupTimeout: const Duration(milliseconds: 5),
    );

    await service.signOut(caregiver: false);

    expect(signedOut, isTrue);
  });
}
