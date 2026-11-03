import 'package:flutter_test/flutter_test.dart';
import 'package:shca/services/emergency_push_service.dart';

void main() {
  test(
    'email acceptance remains visible when no caregiver device is registered',
    () {
      final result = EmergencyPushResult.fromJson({
        'accepted': 0,
        'unavailable': 1,
        'linkedCaregivers': 1,
        'error': 'No caregiver phone is registered for push.',
        'emailAccepted': 1,
        'emailUnavailable': 0,
      });
      expect(result.delivered, isFalse);
      expect(result.anyChannelAccepted, isTrue);
      expect(result.allChannelsAccepted, isFalse);
      expect(
        result.deliverySummary,
        contains('No caregiver phone is registered'),
      );
      expect(result.deliverySummary, contains('Email: accepted'));
    },
  );

  test('both channels must succeed before showing a complete success', () {
    final result = EmergencyPushResult.fromJson({
      'accepted': 1,
      'unavailable': 0,
      'linkedCaregivers': 1,
      'emailAccepted': 1,
      'emailUnavailable': 0,
    });
    expect(result.allChannelsAccepted, isTrue);
    expect(result.deliverySummary, contains('Push: accepted'));
    expect(result.deliverySummary, contains('Email: accepted'));
  });

  test(
    'partial email delivery and legacy responses cannot imply full success',
    () {
      final partial = EmergencyPushResult.fromJson({
        'accepted': 1,
        'unavailable': 0,
        'linkedCaregivers': 2,
        'emailAccepted': 1,
        'emailUnavailable': 1,
        'emailError': 'One email failed.',
      });
      expect(partial.allChannelsAccepted, isFalse);
      expect(partial.deliverySummary, contains('One email failed.'));
      final legacy = EmergencyPushResult.fromJson({'accepted': 1});
      expect(legacy.allChannelsAccepted, isFalse);
      expect(
        legacy.deliverySummary,
        contains('Acceptance could not be confirmed'),
      );
    },
  );
}
