import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

/// Queries each linked account separately so rules can verify its active link.
/// A recipient-only query cannot prove that all returned accounts are linked.
Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
watchCaregiverEmergencyAlerts({
  required String caregiverId,
  required Future<Iterable<String>> elderlyIds,
  FirebaseFirestore? firestore,
  int limitPerElderly = 30,
}) {
  // Handle loading errors now, even when a lazy list has not mounted its alert
  // card yet. Keep the result so every later subscriber receives the same IDs
  // or a stream error rather than an unhandled Future error.
  final linked = _resolveAlertAccounts(elderlyIds);
  return Stream.multi((controller) {
    var cancelled = false;
    Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> load() async* {
      final result = await linked;
      if (cancelled) return;
      if (result.error != null) {
        Error.throwWithStackTrace(result.error!, result.stackTrace!);
      }
      if (result.ids.isEmpty) {
        yield const [];
        return;
      }
      final db = firestore ?? FirebaseFirestore.instance;
      yield* mergeCaregiverAlertStreams([
        for (final id in result.ids)
          db
              .collection('emergency_alerts')
              .where('elderlyId', isEqualTo: id)
              .where('recipientCaregiverIds', arrayContains: caregiverId)
              .orderBy('createdAt', descending: true)
              .limit(limitPerElderly)
              .snapshots()
              .map((snapshot) => snapshot.docs),
      ]);
    }

    // A list item may be disposed and recreated as account cards load or the
    // user scrolls. Every listener gets fresh query streams and merge state.
    final subscription = load().listen(
      controller.addSync,
      onError: controller.addErrorSync,
      onDone: controller.closeSync,
    );
    controller.onPause = subscription.pause;
    controller.onResume = subscription.resume;
    controller.onCancel = () {
      cancelled = true;
      return subscription.cancel();
    };
  });
}

Future<({Set<String> ids, Object? error, StackTrace? stackTrace})>
_resolveAlertAccounts(Future<Iterable<String>> elderlyIds) async {
  try {
    return (
      ids: (await elderlyIds).where((id) => id.isNotEmpty).toSet(),
      error: null,
      stackTrace: null,
    );
  } catch (error, stackTrace) {
    return (ids: <String>{}, error: error, stackTrace: stackTrace);
  }
}

/// Waits for every account's first result and replaces, rather than appends,
/// subsequent snapshots. A denied source fails the combined stream closed.
Stream<List<T>> mergeCaregiverAlertStreams<T>(List<Stream<List<T>>> sources) {
  if (sources.isEmpty) return Stream.value(<T>[]);
  final latest = <int, List<T>>{};
  final subscriptions = <StreamSubscription<List<T>>>[];
  var failed = false;
  var completed = 0;
  late final StreamController<List<T>> controller;
  controller = StreamController<List<T>>(
    onListen: () {
      for (var index = 0; index < sources.length; index++) {
        final sourceIndex = index;
        subscriptions.add(
          sources[index].listen(
            (items) {
              if (failed) return;
              latest[sourceIndex] = List<T>.of(items);
              if (latest.length == sources.length) {
                controller.add([
                  for (var i = 0; i < sources.length; i++) ...latest[i]!,
                ]);
              }
            },
            onError: (Object error, StackTrace stack) {
              if (failed) return;
              failed = true;
              latest.clear();
              controller.addError(error, stack);
            },
            onDone: () {
              completed++;
              if (completed == sources.length) controller.close();
            },
          ),
        );
      }
    },
    onPause: () {
      for (final subscription in subscriptions) {
        subscription.pause();
      }
    },
    onResume: () {
      for (final subscription in subscriptions) {
        subscription.resume();
      }
    },
    onCancel: () async {
      await Future.wait(
        subscriptions.map((subscription) => subscription.cancel()),
      );
    },
  );
  return controller.stream;
}
