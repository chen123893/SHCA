# Activity and fall models for Flutter Android

Two separate models are ready for deployment:

| Target | Test activity accuracy | Macro F1 | Fall precision | Fall recall | TFLite size |
|---|---:|---:|---:|---:|---:|
| Phone (MobiAct) | 95.86% | 92.03% | 98.57% | 95.83% | 304,780 bytes |
| Wrist wearable (WEDA-FALL) | 80.42% | 74.49% | 83.44% | 81.44% | 305,296 bytes |

These are subject-independent test results: people in the test set were not used
for training or threshold selection.

## What was corrected in the raw data pipeline

The MobiAct accelerometer and gyroscope files are not row-aligned. Their measured
rates differ substantially, so truncating both files and concatenating row `n`
with row `n` creates false sensor pairs. WEDA-FALL is nominally 50 Hz but also has
timestamp jitter and occasional gaps.

The implemented pipeline therefore:

1. parses both raw timestamp streams independently;
2. removes invalid/duplicate timestamps;
3. interpolates both sensors onto a shared 50 Hz timeline;
4. rejects windows crossing a sensor gap greater than 100 ms;
5. creates 128-sample windows with a 64-sample step;
6. derives acceleration and gyroscope magnitude;
7. fits normalization only on training subjects;
8. keeps subjects disjoint across training, validation and test sets.

MobiAct does not provide manual within-recording fall intervals. To avoid marking
long pre-fall and post-fall periods as falls, only impact-centred windows are used
from each fall trial. WEDA-FALL windows use its supplied manual fall intervals.

## Model contract

- Input: `float32[1, 128, 8]`
- Rate: 50 Hz
- Duration: 2.56 seconds
- Step: 64 samples / 1.28 seconds
- Feature order: accelerometer x/y/z in m/s^2, gyroscope x/y/z in rad/s,
  acceleration magnitude, gyroscope magnitude
- Scaling: `(raw - mean) / scale`, using the target's `scaler.json`
- Output 1: activity softmax
- Output 2: binary fall probability

Phone activities: standing, walking, running, jumping, chair transition, vehicle
transition and fall. Stair walking is grouped with walking.

Wearable activities: walking, running, chair transition, crouching, stumble,
jumping, hand activity and fall. Stair walking is grouped with walking; table
hits, claps and door actions are grouped as hand activity.

The phone model's validation-selected fall-window threshold is `0.4145007`; the
wearable model's is `0.5074646`. For an actual alert, use the separate event
threshold from `metadata.json` and require 2 positive windows among the last 3:

| Target | Alert threshold | Test fall-event recall | Test false alerts | Recorded non-fall time |
|---|---:|---:|---:|---:|
| Phone | 0.40 | 95.83% (23/24) | 0 | 0.533 h |
| Wrist wearable | 0.80 | 96.00% (48/50) | 3 | 0.363 h |

The event policy deliberately uses a higher wrist threshold than the single-
window classifier. The reported recording durations are short, especially for
false-alert measurement, so these rates must not be extrapolated to an all-day
deployment.

## Files

- `saved_model/deployment/phone/activity_fall_model.tflite`
- `saved_model/deployment/wearable/activity_fall_model.tflite`
- each target folder also includes `scaler.json`, `labels.txt`, `metadata.json`,
  `split.json`, `best_model.keras` and `confusion_matrix.png`
- `flutter_integration/fall_activity_classifier.dart` is the Flutter inference
  helper
- `flutter_integration/README.md` gives the Android integration sequence

The older `saved_model/wedafall_cnn.keras` and `wedafall_scaler.pkl` are legacy
notebook artifacts. Do not deploy them; they do not use the corrected synchronized
pipeline or the current Flutter contract.

## Reproduce and verify

From the project root:

```bash
.venv/bin/python -m ml_pipeline.train --dataset both --rebuild-cache
.venv/bin/python -m ml_pipeline.verify_exports
```

Omit `--rebuild-cache` to reuse the audited synchronized window caches.

## Honest limitations before an emergency-use claim

This is suitable for an FYP prototype and controlled demonstration, but it is not
yet a medical device. Both datasets contain staged falls and the wrist test is
the weaker of the two. The alert false-positive estimates also cover less than
one hour of non-fall test recordings per model, which is too short to establish a
reliable all-day false-alarm rate.

Before allowing automatic caregiver contact, collect a target-device pilot set
from the actual phone pocket/waist position and actual watch, including normal
daily living, dropped devices, removing the watch, vehicle movement, jumping and
near-falls. Keep those participants out of retraining until the final evaluation,
then report sensitivity, precision, event false alarms per hour, inference latency
and battery drain. Always retain the 15-second user cancellation screen.
