import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shca/services/caregiver_alert_service.dart';

typedef Documents = List<QueryDocumentSnapshot<Map<String, dynamic>>>;

// Real service/query lifecycle, with no Firebase connection or live alert data.
class _Firestore extends Fake implements FirebaseFirestore {
  int opens = 0, cancellations = 0;
  final sessions = <StreamController<QuerySnapshot<Map<String, dynamic>>>>[];
  final queries = <Map<String, Object?>>[];
  int get active => opens - cancellations;

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    expect(path, 'emergency_alerts');
    return _Query(this);
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> open(Map<String, Object?> query) {
    late final StreamController<QuerySnapshot<Map<String, dynamic>>> session;
    session = StreamController<QuerySnapshot<Map<String, dynamic>>>(
      onListen: () {
        opens++;
        queries.add(query);
        session.add(_Snapshot());
      },
      onCancel: () => cancellations++,
    );
    sessions.add(session);
    return session.stream;
  }

  Future<void> close() async {
    for (final session in sessions) {
      // A cancelled async loader may have constructed a source without ever
      // listening; closing that unused controller has no completion listener.
      unawaited(session.close());
    }
  }
}

// Query is only implemented by this test double; production uses the SDK.
// ignore: subtype_of_sealed_class
class _Query extends Fake implements CollectionReference<Map<String, dynamic>> {
  _Query(this.store);
  final _Firestore store;
  final filters = <String, Object?>{};
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #where) {
      filters[invocation.positionalArguments.first as String] =
          invocation.namedArguments[#isEqualTo] ??
          invocation.namedArguments[#arrayContains];
      return this;
    }
    if (invocation.memberName == #orderBy || invocation.memberName == #limit) {
      return this;
    }
    if (invocation.memberName == #snapshots) return store.open(Map.of(filters));
    return super.noSuchMethod(invocation);
  }
}

class _Snapshot extends Fake implements QuerySnapshot<Map<String, dynamic>> {
  @override
  Documents get docs => const [];
}

Widget _status(Stream<Documents> stream) => StreamBuilder<Documents>(
  stream: stream,
  builder: (context, snapshot) => SizedBox(
    height: 48,
    child: Text(
      snapshot.hasError
          ? 'Alert error'
          : snapshot.hasData
          ? 'Alerts ready'
          : 'Loading alerts',
    ),
  ),
);

void main() {
  test(
    'completed alert stream can be reopened without refreshing linked accounts',
    () async {
      final stream = watchCaregiverEmergencyAlerts(
        caregiverId: 'caregiver',
        elderlyIds: Future.value(const <String>[]),
      );
      expect(await stream.toList(), [[]]);
      expect(await stream.toList(), [[]]);
    },
  );

  test(
    'reattaching starts fresh queries and cancels the previous listeners',
    () async {
      final store = _Firestore();
      final stream = watchCaregiverEmergencyAlerts(
        caregiverId: 'caregiver',
        elderlyIds: Future.value(['elderly']),
        firestore: store,
      );
      for (var i = 0; i < 4; i++) {
        expect(await stream.first, isEmpty);
        await Future<void>.delayed(Duration.zero);
        expect(store.active, 0);
      }
      expect(store.opens, 4);
      expect(
        store.queries.every(
          (q) =>
              q['elderlyId'] == 'elderly' &&
              q['recipientCaregiverIds'] == 'caregiver',
        ),
        isTrue,
      );
      await store.close();
    },
  );

  test(
    'two consumers have independent subscriptions and cancellation',
    () async {
      final store = _Firestore();
      final stream = watchCaregiverEmergencyAlerts(
        caregiverId: 'caregiver',
        elderlyIds: Future.value(['elderly']),
        firestore: store,
      );
      final firstReady = Completer<void>(), secondReady = Completer<void>();
      final a = stream.listen((_) {
        if (!firstReady.isCompleted) firstReady.complete();
      });
      final b = stream.listen((_) {
        if (!secondReady.isCompleted) secondReady.complete();
      });
      await Future.wait([firstReady.future, secondReady.future]);
      expect(store.active, 2);
      await a.cancel();
      expect(store.active, 1);
      await b.cancel();
      expect(store.active, 0);
      await store.close();
    },
  );

  test(
    'linked-account failure is handled even before the alert card is visible',
    () async {
      final ids = Completer<Iterable<String>>();
      final error = StateError('linked accounts unavailable');
      final stream = watchCaregiverEmergencyAlerts(
        caregiverId: 'caregiver',
        elderlyIds: ids.future,
      );
      ids.completeError(error);
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        stream,
        emitsInOrder([emitsError(same(error)), emitsDone]),
      );
    },
  );

  test(
    'cancelling during initial loading cannot leave an account listener running',
    () async {
      final store = _Firestore();
      final ids = Completer<Iterable<String>>();
      final stream = watchCaregiverEmergencyAlerts(
        caregiverId: 'caregiver',
        elderlyIds: ids.future,
        firestore: store,
      );
      final subscription = stream.listen(
        (_) => fail('A cancelled card received data'),
      );
      final cancelled = subscription.cancel();
      ids.complete(['elderly']);
      await cancelled;
      await Future<void>.delayed(Duration.zero);
      expect(store.active, 0);
      await store.close();
    },
  );

  test(
    'paused listeners resume and cancel without retaining account queries',
    () async {
      final store = _Firestore();
      final stream = watchCaregiverEmergencyAlerts(
        caregiverId: 'caregiver',
        elderlyIds: Future.value(['elderly']),
        firestore: store,
      );
      var events = 0;
      final subscription = stream.listen((_) => events++);
      await Future<void>.delayed(Duration.zero);
      expect(events, 1);
      subscription.pause();
      store.sessions.single.add(_Snapshot());
      await Future<void>.delayed(Duration.zero);
      expect(events, 1);
      subscription.resume();
      await Future<void>.delayed(Duration.zero);
      expect(events, 2);
      subscription.pause();
      await subscription.cancel();
      expect(store.active, 0);
      await store.close();
    },
  );

  test(
    'a failed query can be reopened without reusing its failed merge state',
    () async {
      final store = _Firestore();
      final stream = watchCaregiverEmergencyAlerts(
        caregiverId: 'caregiver',
        elderlyIds: Future.value(['elderly']),
        firestore: store,
      );
      final errors = <Object>[];
      final subscription = stream.listen(
        (_) {},
        onError: (Object error) => errors.add(error),
      );
      await Future<void>.delayed(Duration.zero);
      final denied = FirebaseException(
        plugin: 'cloud_firestore',
        code: 'permission-denied',
      );
      store.sessions.single.addError(denied);
      await Future<void>.delayed(Duration.zero);
      expect(errors, [same(denied)]);
      await subscription.cancel();
      expect(await stream.first, isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(store.opens, 2);
      expect(store.active, 0);
      await store.close();
    },
  );

  test(
    'a linked-account error after cancellation does not escape to the app',
    () async {
      final ids = Completer<Iterable<String>>();
      final stream = watchCaregiverEmergencyAlerts(
        caregiverId: 'caregiver',
        elderlyIds: ids.future,
      );
      final subscription = stream.listen(
        (_) => fail('Cancelled stream emitted data'),
        onError: (Object error) => fail('Cancelled stream emitted an error'),
      );
      final cancelled = subscription.cancel();
      ids.completeError(StateError('offline'));
      await cancelled;
      await Future<void>.delayed(Duration.zero);
    },
  );

  testWidgets(
    'startup card growth and repeated scrolling reopen the alert without Bad state',
    (tester) async {
      tester.view.physicalSize = const Size(400, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = _Firestore();
      final loaded = ValueNotifier(false);
      final scroll = ScrollController();
      final stream = watchCaregiverEmergencyAlerts(
        caregiverId: 'caregiver',
        elderlyIds: Future.value(['elderly']),
        firestore: store,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              controller: scroll,
              scrollCacheExtent: const ScrollCacheExtent.pixels(0),
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: loaded,
                  builder: (_, ready, child) =>
                      SizedBox(height: ready ? 1800 : 40),
                ),
                _status(stream),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Alerts ready'), findsOneWidget);
      // Linked account cards replace a small loading placeholder on first opening.
      loaded.value = true;
      await tester.pumpAndSettle();
      expect(store.active, 0);
      for (var i = 0; i < 4; i++) {
        scroll.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Alerts ready'), findsOneWidget);
        expect(store.active, 1);
        scroll.jumpTo(0);
        await tester.pumpAndSettle();
        expect(store.active, 0);
      }
      await tester.pumpWidget(const SizedBox());
      loaded.dispose();
      scroll.dispose();
      await store.close();
    },
  );

  testWidgets('leaving and reopening a page can reuse the saved alert stream', (
    tester,
  ) async {
    final store = _Firestore();
    final stream = watchCaregiverEmergencyAlerts(
      caregiverId: 'caregiver',
      elderlyIds: Future.value(['elderly']),
      firestore: store,
    );
    for (var i = 0; i < 3; i++) {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: _status(stream))),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Alerts ready'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(store.active, 0);
    }
    await store.close();
  });
}
