# Flutter Android integration

Use the phone model for a phone carried at the MobiAct body position, and the
wearable model for a wrist watch. Do not swap the two models: sensor orientation
and body position are part of what each model learned.

## 1. Copy model assets

Copy the following folder into your Flutter project, preserving the phone and
wearable subfolders:

```text
saved_model/deployment/
  phone/activity_fall_model.tflite
  phone/scaler.json
  phone/metadata.json
  wearable/activity_fall_model.tflite
  wearable/scaler.json
  wearable/metadata.json
```

Add the assets and dependency to `pubspec.yaml`:

```yaml
dependencies:
  tflite_flutter: ^0.12.1

flutter:
  assets:
    - assets/models/phone/
    - assets/models/wearable/
```

Copy `fall_activity_classifier.dart` to your Flutter `lib/` directory.

## 2. Load the correct model

```dart
final classifier = await FallActivityClassifier.fromAssets(
  modelAsset: 'assets/models/phone/activity_fall_model.tflite',
  scalerAsset: 'assets/models/phone/scaler.json',
  metadataAsset: 'assets/models/phone/metadata.json',
);
final alertGate = FallAlertGate(threshold: classifier.alertThreshold);
```

Use `wearable/...` for the watch build.

## 3. Prepare sensor windows

- Request accelerometer and gyroscope data at 50 Hz.
- Use sensor timestamps to interpolate both streams onto the same 20 ms grid.
- Preserve SI units: acceleration in m/s^2 including gravity and angular rate in
  rad/s.
- Keep a rolling buffer of 128 synchronized samples (2.56 seconds).
- Run inference every 64 new samples (1.28 seconds).
- Do not combine accelerometer and gyroscope callbacks by list index. Android
  delivers the two sensors independently and at different real rates.

Then classify and apply the event-level alert rule:

```dart
final result = classifier.classify(synchronizedWindow);
final shouldStartCancellationCountdown =
    alertGate.observe(result.fallProbability, DateTime.now());

setState(() {
  currentActivity = result.activity;
  activityConfidence = result.activityConfidence;
});

if (shouldStartCancellationCountdown) {
  // Show the 15-second user cancellation screen before notifying a caregiver.
}
```

Run inference in an isolate/background service for continuous monitoring. Android
also requires a foreground service and a persistent notification for reliable
long-running sensor collection. Battery optimization, sensor availability and
background restrictions must be tested on the actual phone/watch brands used in
the FYP demonstration.

## Important safety behavior

The activity label and fall output are separate heads. Display the activity from
`result.activity`, but decide a possible fall using `fallProbability` and the
2-of-3 `FallAlertGate`. A single high window should not immediately contact a
caregiver. The exported metadata recommends a 15-second cancellation period and
a 30-second alert cooldown.
