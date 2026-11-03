import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// One accelerometer + gyroscope sample after timestamp synchronization.
///
/// Accelerometer values must be m/s^2 (including gravity) and gyroscope values
/// must be rad/s. Feed exactly 50 samples per second to match model training.
class ImuSample {
  const ImuSample({
    required this.accX,
    required this.accY,
    required this.accZ,
    required this.gyroX,
    required this.gyroY,
    required this.gyroZ,
  });

  final double accX;
  final double accY;
  final double accZ;
  final double gyroX;
  final double gyroY;
  final double gyroZ;
}

class ActivityFallResult {
  const ActivityFallResult({
    required this.activity,
    required this.activityConfidence,
    required this.fallProbability,
    required this.isFallWindow,
  });

  final String activity;
  final double activityConfidence;
  final double fallProbability;
  final bool isFallWindow;
}

/// Runs either exported phone or wearable model.
///
/// Keep one instance alive while monitoring; creating an Interpreter for every
/// window is unnecessarily expensive.
class FallActivityClassifier {
  FallActivityClassifier._({
    required Interpreter interpreter,
    required List<String> labels,
    required List<double> mean,
    required List<double> scale,
    required this.fallThreshold,
    required this.alertThreshold,
    required this.windowSize,
    required this.sampleRateHz,
  }) : _interpreter = interpreter,
       _labels = labels,
       _mean = mean,
       _scale = scale {
    final inputShape = _interpreter.getInputTensor(0).shape;
    if (inputShape.length != 3 ||
        inputShape[0] != 1 ||
        inputShape[1] != windowSize ||
        inputShape[2] != 8) {
      throw StateError('Unexpected model input shape: $inputShape');
    }

    for (
      var ordinal = 0;
      ordinal < _interpreter.getOutputTensors().length;
      ordinal++
    ) {
      final shape = _interpreter.getOutputTensor(ordinal).shape;
      if (shape.length == 2 && shape[0] == 1 && shape[1] == labels.length) {
        _activityOutputOrdinal = ordinal;
      } else if (shape.length == 2 && shape[0] == 1 && shape[1] == 1) {
        _fallOutputOrdinal = ordinal;
      }
    }
    if (_activityOutputOrdinal < 0 || _fallOutputOrdinal < 0) {
      throw StateError('The activity/fall output tensors were not found.');
    }
  }

  final Interpreter _interpreter;
  final List<String> _labels;
  final List<double> _mean;
  final List<double> _scale;
  final double fallThreshold;
  final double alertThreshold;
  final int windowSize;
  final int sampleRateHz;
  int _activityOutputOrdinal = -1;
  int _fallOutputOrdinal = -1;

  static Future<FallActivityClassifier> fromAssets({
    required String modelAsset,
    required String scalerAsset,
    required String metadataAsset,
  }) async {
    final scaler = jsonDecode(
      await rootBundle.loadString(scalerAsset),
    ) as Map<String, dynamic>;
    final metadata = jsonDecode(
      await rootBundle.loadString(metadataAsset),
    ) as Map<String, dynamic>;
    final policy = metadata['recommended_alert_policy'] as Map<String, dynamic>;

    final labels = (metadata['labels'] as List).cast<String>();
    final mean = (scaler['mean'] as List)
        .map((value) => (value as num).toDouble())
        .toList(growable: false);
    final scale = (scaler['scale'] as List)
        .map((value) => (value as num).toDouble())
        .toList(growable: false);
    if (mean.length != 8 || scale.length != 8) {
      throw StateError('Scaler must contain exactly 8 features.');
    }

    return FallActivityClassifier._(
      interpreter: await Interpreter.fromAsset(modelAsset),
      labels: labels,
      mean: mean,
      scale: scale,
      fallThreshold: (metadata['fall_threshold'] as num).toDouble(),
      alertThreshold: (policy['threshold'] as num).toDouble(),
      windowSize: (metadata['window_size'] as num).toInt(),
      sampleRateHz: (metadata['sampling_rate_hz'] as num).toInt(),
    );
  }

  ActivityFallResult classify(List<ImuSample> samples) {
    if (samples.length != windowSize) {
      throw ArgumentError(
        'Expected $windowSize samples, got ${samples.length}.',
      );
    }

    final inputWindow = samples
        .map((sample) {
          final accMagnitude = math.sqrt(
            sample.accX * sample.accX +
                sample.accY * sample.accY +
                sample.accZ * sample.accZ,
          );
          final gyroMagnitude = math.sqrt(
            sample.gyroX * sample.gyroX +
                sample.gyroY * sample.gyroY +
                sample.gyroZ * sample.gyroZ,
          );
          final raw = <double>[
            sample.accX,
            sample.accY,
            sample.accZ,
            sample.gyroX,
            sample.gyroY,
            sample.gyroZ,
            accMagnitude,
            gyroMagnitude,
          ];
          return List<double>.generate(
            8,
            (index) => (raw[index] - _mean[index]) / _scale[index],
            growable: false,
          );
        })
        .toList(growable: false);

    final activityOutput = <List<double>>[
      List<double>.filled(_labels.length, 0),
    ];
    final fallOutput = <List<double>>[List<double>.filled(1, 0)];
    _interpreter.runForMultipleInputs(
      [
        <List<List<double>>>[inputWindow],
      ],
      {_activityOutputOrdinal: activityOutput, _fallOutputOrdinal: fallOutput},
    );

    final probabilities = activityOutput.first;
    var bestIndex = 0;
    for (var index = 1; index < probabilities.length; index++) {
      if (probabilities[index] > probabilities[bestIndex]) bestIndex = index;
    }
    final fallProbability = fallOutput.first.first;
    return ActivityFallResult(
      activity: _labels[bestIndex],
      activityConfidence: probabilities[bestIndex],
      fallProbability: fallProbability,
      isFallWindow: fallProbability >= fallThreshold,
    );
  }

  void close() => _interpreter.close();
}

/// Converts window probabilities into a safer 2-of-3 alert decision.
class FallAlertGate {
  FallAlertGate({
    required this.threshold,
    this.minimumPositiveWindows = 2,
    this.rollingWindowCount = 3,
    this.cooldown = const Duration(seconds: 30),
  });

  final double threshold;
  final int minimumPositiveWindows;
  final int rollingWindowCount;
  final Duration cooldown;
  final Queue<bool> _history = Queue<bool>();
  DateTime? _lastAlert;

  bool observe(double fallProbability, DateTime now) {
    _history.addLast(fallProbability >= threshold);
    while (_history.length > rollingWindowCount) {
      _history.removeFirst();
    }
    final positives = _history.where((value) => value).length;
    final outsideCooldown =
        _lastAlert == null || now.difference(_lastAlert!) >= cooldown;
    if (positives >= minimumPositiveWindows && outsideCooldown) {
      _lastAlert = now;
      _history.clear();
      return true;
    }
    return false;
  }

  void reset() {
    _history.clear();
    _lastAlert = null;
  }
}
