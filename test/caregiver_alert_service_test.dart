import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shca/services/caregiver_alert_service.dart';

Future<void> flushEvents() => Future<void>.delayed(Duration.zero);

void main() {
  test('no linked sources gives an empty alert list', () async {
    expect(await mergeCaregiverAlertStreams<String>([]).toList(), [[]]);
  });

  test('empty linked IDs need no Firebase connection', () async {
    expect(
      await watchCaregiverEmergencyAlerts(
        caregiverId: 'caregiver',
        elderlyIds: Future.value(const <String>[]),
      ).toList(),
      [[]],
    );
  });

  test(
    'waits for all accounts before reporting their combined alerts',
    () async {
      final a = StreamController<List<String>>();
      final b = StreamController<List<String>>();
      final events = <List<String>>[];
      final subscription = mergeCaregiverAlertStreams([
        a.stream,
        b.stream,
      ]).listen(events.add);
      a.add(['a-alert']);
      await flushEvents();
      expect(events, isEmpty);
      b.add(['b-alert']);
      await flushEvents();
      expect(events, [
        ['a-alert', 'b-alert'],
      ]);
      await subscription.cancel();
      await a.close();
      await b.close();
    },
  );

  test('new snapshots replace previous alerts without duplicates', () async {
    final a = StreamController<List<String>>();
    final b = StreamController<List<String>>();
    final events = <List<String>>[];
    final subscription = mergeCaregiverAlertStreams([
      a.stream,
      b.stream,
    ]).listen(events.add);
    a.add(['old']);
    b.add(['other']);
    await flushEvents();
    a.add(['new']);
    await flushEvents();
    expect(events.last, ['new', 'other']);
    a.add([]);
    await flushEvents();
    expect(events.last, ['other']);
    await subscription.cancel();
    await a.close();
    await b.close();
  });

  test(
    'a denied source forwards its error and cannot emit stale alerts',
    () async {
      final a = StreamController<List<String>>();
      final b = StreamController<List<String>>();
      final events = <List<String>>[];
      final errors = <Object>[];
      final subscription = mergeCaregiverAlertStreams([
        a.stream,
        b.stream,
      ]).listen(events.add, onError: (Object error) => errors.add(error));
      a.add(['a-alert']);
      b.add(['b-alert']);
      await flushEvents();
      final error = StateError('permission-denied');
      a.addError(error);
      await flushEvents();
      b.add(['later']);
      await flushEvents();
      expect(errors, [same(error)]);
      expect(events, [
        ['a-alert', 'b-alert'],
      ]);
      await subscription.cancel();
      await a.close();
      await b.close();
    },
  );

  test(
    'cancelling the combined stream cancels every account listener',
    () async {
      var cancellations = 0;
      final a = StreamController<List<String>>(onCancel: () => cancellations++);
      final b = StreamController<List<String>>(onCancel: () => cancellations++);
      final subscription = mergeCaregiverAlertStreams([
        a.stream,
        b.stream,
      ]).listen((_) {});
      await subscription.cancel();
      expect(cancellations, 2);
      await a.close();
      await b.close();
    },
  );
}
