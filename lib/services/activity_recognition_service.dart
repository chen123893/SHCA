import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

enum ActivityMonitorState { starting, collecting, active, unavailable, stopped }

@immutable
class ActivityDecision {
  const ActivityDecision(this.label, this.confidence);

  final String label;
  final double confidence;
}

/// Keeps the dashboard focused on meaningful daily activities.
///
/// `vehicle_transition` is intentionally excluded because that short MobiAct
/// protocol class is orientation-sensitive and is not a useful elderly home
/// status. A weak remaining prediction is reported as uncertain instead of
/// being relabelled as sitting or sleeping without training evidence.
@visibleForTesting
ActivityDecision selectPrimaryActivity({
  required List<String> labels,
  required List<double> probabilities,
  required int fallIndex,
  required double fallProbability,
  required double fallThreshold,
  double minimumConfidence = 0.35,
  double minimumActivityFallConfidence = 0.55,
}) {
  if (labels.length != probabilities.length) {
    throw ArgumentError('Labels and probabilities must have the same length.');
  }
  final activityFallProbability =
      fallIndex >= 0 && fallIndex < probabilities.length
      ? probabilities[fallIndex]
      : 0.0;
  if (fallProbability >= fallThreshold &&
      activityFallProbability >= minimumActivityFallConfidence) {
    return ActivityDecision('fall', fallProbability.clamp(0, 1));
  }

  var bestIndex = -1;
  var bestProbability = -1.0;
  for (var index = 0; index < probabilities.length; index++) {
    if (index == fallIndex || labels[index] == 'vehicle_transition') continue;
    if (probabilities[index] > bestProbability) {
      bestIndex = index;
      bestProbability = probabilities[index];
    }
  }
  if (bestIndex < 0 || bestProbability < minimumConfidence) {
    return ActivityDecision(
      'activity_unknown',
      math.max(bestProbability, 0.0).clamp(0.0, 1.0).toDouble(),
    );
  }
  return ActivityDecision(labels[bestIndex], bestProbability.clamp(0, 1));
}

@immutable
class ActivitySnapshot {
  const ActivitySnapshot({
    this.label = 'Preparing sensors',
    this.confidence = 0,
    this.fallProbability = 0,
    this.updatedAt,
    this.state = ActivityMonitorState.starting,
    this.possibleFall = false,
    this.message = 'Loading the activity model…',
  });

  final String label;
  final double confidence;
  final double fallProbability;
  final DateTime? updatedAt;
  final ActivityMonitorState state;
  final bool possibleFall;
  final String message;
}

abstract interface class ActivityMonitor implements Listenable {
  ActivitySnapshot get snapshot;

  Future<void> start();

  Future<void> stop();

  void acknowledgePossibleFall();
}

/// Synchronizes Android motion sensors and runs the exported activity/fall CNN.
///
/// This service intentionally uses [accelerometerEventStream], which includes
/// gravity and reports m/s², and [gyroscopeEventStream], which reports rad/s.
/// It selects the exact features declared by each model's metadata. The phone
/// model uses motion magnitudes so its predictions do not depend on orientation.
class ActivityRecognitionService extends ChangeNotifier
    implements ActivityMonitor {
  factory ActivityRecognitionService.phone() => _phoneInstance;

  static final ActivityRecognitionService _phoneInstance =
      ActivityRecognitionService._(
        modelAsset: 'assets/models/phone/activity_fall_model.tflite',
        scalerAsset: 'assets/models/phone/scaler.json',
        metadataAsset: 'assets/models/phone/metadata.json',
      );

  ActivityRecognitionService._({
    required this.modelAsset,
    required this.scalerAsset,
    required this.metadataAsset,
  });

  static const Duration _samplePeriod = Duration(milliseconds: 20);
  static const Duration _interpolationDelay = Duration(milliseconds: 40);
  static const Duration _maximumSensorAge = Duration(milliseconds: 100);
  static const double _minimumFallDisplayProbability = 0.65;
  static const double _minimumFallAlertProbability = 0.70;
  static const double _minimumActivityFallConfidence = 0.55;
  static const int _fallVoteWindowCount = 4;
  static const int _minimumFallVotes = 3;

  final String modelAsset;
  final String scalerAsset;
  final String metadataAsset;

  final List<_TimedVector3> _accelerometer = <_TimedVector3>[];
  final List<_TimedVector3> _gyroscope = <_TimedVector3>[];
  final List<List<double>> _window = <List<double>>[];
  final Queue<bool> _fallHistory = Queue<bool>();

  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;
  StreamSubscription<GyroscopeEvent>? _gyroscopeSubscription;
  Timer? _sampleTimer;
  Interpreter? _interpreter;

  List<String> _labels = const <String>[];
  List<String> _featureNames = const <String>[];
  List<double> _mean = const <double>[];
  List<double> _scale = const <double>[];
  int _windowSize = 128;
  int _stepSize = 64;
  int _activityOutputOrdinal = -1;
  int _fallOutputOrdinal = -1;
  int _fallIndex = -1;
  int _samplesSinceInference = 0;
  bool _hasRunInference = false;
  bool _inferenceRunning = false;
  bool _started = false;
  double _fallThreshold = 0.5;
  double _alertThreshold = 0.5;
  DateTime? _lastPossibleFall;

  ActivitySnapshot _snapshot = const ActivitySnapshot();

  @override
  ActivitySnapshot get snapshot => _snapshot;

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _setSnapshot(
      const ActivitySnapshot(
        label: 'Preparing sensors',
        state: ActivityMonitorState.starting,
        message: 'Loading the on-device activity model…',
      ),
    );

    try {
      await _loadModelContract();
      _accelerometerSubscription =
          accelerometerEventStream(samplingPeriod: _samplePeriod).listen(
            (event) => _addSensorSample(
              _accelerometer,
              _TimedVector3(event.timestamp, event.x, event.y, event.z),
            ),
            onError: _handleSensorError,
            cancelOnError: true,
          );
      _gyroscopeSubscription =
          gyroscopeEventStream(samplingPeriod: _samplePeriod).listen(
            (event) => _addSensorSample(
              _gyroscope,
              _TimedVector3(event.timestamp, event.x, event.y, event.z),
            ),
            onError: _handleSensorError,
            cancelOnError: true,
          );
      _sampleTimer = Timer.periodic(_samplePeriod, (_) => _sampleOnGrid());
      _setSnapshot(
        const ActivitySnapshot(
          label: 'Collecting movement',
          state: ActivityMonitorState.collecting,
          message: 'Keep the phone in your usual pocket or waist position.',
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Unable to start activity recognition: $error\n$stackTrace');
      await _releaseResources();
      _setSnapshot(
        const ActivitySnapshot(
          label: 'Monitoring unavailable',
          state: ActivityMonitorState.unavailable,
          message: 'The motion sensors or activity model could not be opened.',
        ),
      );
    }
  }

  Future<void> _loadModelContract() async {
    final scaler =
        jsonDecode(await rootBundle.loadString(scalerAsset))
            as Map<String, dynamic>;
    final metadata =
        jsonDecode(await rootBundle.loadString(metadataAsset))
            as Map<String, dynamic>;
    final policy = metadata['recommended_alert_policy'] as Map<String, dynamic>;

    _labels = (metadata['labels'] as List<dynamic>).cast<String>();
    _featureNames = (metadata['feature_names'] as List<dynamic>).cast<String>();
    final scalerFeatureNames = (scaler['feature_names'] as List<dynamic>)
        .cast<String>();
    _mean = (scaler['mean'] as List<dynamic>)
        .map((value) => (value as num).toDouble())
        .toList(growable: false);
    _scale = (scaler['scale'] as List<dynamic>)
        .map((value) => (value as num).toDouble())
        .toList(growable: false);
    _windowSize = (metadata['window_size'] as num).toInt();
    _stepSize = (metadata['step_size'] as num).toInt();
    _fallIndex = (metadata['fall_label_index'] as num).toInt();
    _fallThreshold = (metadata['fall_threshold'] as num).toDouble();
    _alertThreshold = (policy['threshold'] as num).toDouble();

    const supportedFeatures = <String>{
      'acc_x_m_s2',
      'acc_y_m_s2',
      'acc_z_m_s2',
      'gyro_x_rad_s',
      'gyro_y_rad_s',
      'gyro_z_rad_s',
      'acc_magnitude_m_s2',
      'gyro_magnitude_rad_s',
    };
    if (_mean.length != _featureNames.length ||
        _scale.length != _featureNames.length ||
        !listEquals(_featureNames, scalerFeatureNames) ||
        !_featureNames.every(supportedFeatures.contains) ||
        _labels.isEmpty ||
        _windowSize != 128) {
      throw const FormatException('Invalid SHCA model metadata or scaler.');
    }

    _interpreter = await Interpreter.fromAsset(modelAsset);
    final inputShape = _interpreter!.getInputTensor(0).shape;
    if (!listEquals(inputShape, <int>[1, _windowSize, _featureNames.length])) {
      throw StateError('Unexpected activity model input shape: $inputShape');
    }

    final outputs = _interpreter!.getOutputTensors();
    for (var ordinal = 0; ordinal < outputs.length; ordinal++) {
      final shape = outputs[ordinal].shape;
      if (listEquals(shape, <int>[1, _labels.length])) {
        _activityOutputOrdinal = ordinal;
      } else if (listEquals(shape, const <int>[1, 1])) {
        _fallOutputOrdinal = ordinal;
      }
    }
    if (_activityOutputOrdinal < 0 || _fallOutputOrdinal < 0) {
      throw StateError('Activity/fall output tensors were not found.');
    }
  }

  void _addSensorSample(List<_TimedVector3> buffer, _TimedVector3 sample) {
    buffer.add(sample);
    final cutoff = sample.timestamp.subtract(const Duration(milliseconds: 600));
    buffer.removeWhere((row) => row.timestamp.isBefore(cutoff));
  }

  void _sampleOnGrid() {
    if (_snapshot.state == ActivityMonitorState.unavailable) return;
    final target = DateTime.now().subtract(_interpolationDelay);
    final acc = _interpolate(_accelerometer, target);
    final gyro = _interpolate(_gyroscope, target);
    if (acc == null || gyro == null) return;

    final availableFeatures = <String, double>{
      'acc_x_m_s2': acc.x,
      'acc_y_m_s2': acc.y,
      'acc_z_m_s2': acc.z,
      'gyro_x_rad_s': gyro.x,
      'gyro_y_rad_s': gyro.y,
      'gyro_z_rad_s': gyro.z,
      'acc_magnitude_m_s2': math.sqrt(
        acc.x * acc.x + acc.y * acc.y + acc.z * acc.z,
      ),
      'gyro_magnitude_rad_s': math.sqrt(
        gyro.x * gyro.x + gyro.y * gyro.y + gyro.z * gyro.z,
      ),
    };
    final raw = _featureNames
        .map((feature) => availableFeatures[feature]!)
        .toList(growable: false);
    final scaled = List<double>.generate(
      _featureNames.length,
      (index) => (raw[index] - _mean[index]) / _scale[index],
      growable: false,
    );
    _window.add(scaled);
    if (_window.length > _windowSize) _window.removeAt(0);
    _samplesSinceInference++;

    final shouldInfer =
        _window.length == _windowSize &&
        (!_hasRunInference || _samplesSinceInference >= _stepSize);
    if (shouldInfer && !_inferenceRunning) _runInference();
  }

  _TimedVector3? _interpolate(List<_TimedVector3> rows, DateTime target) {
    if (rows.isEmpty) return null;
    _TimedVector3? before;
    _TimedVector3? after;
    for (final row in rows) {
      if (!row.timestamp.isAfter(target)) before = row;
      if (!row.timestamp.isBefore(target)) {
        after = row;
        break;
      }
    }

    if (before == null || after == null) {
      final nearest = before ?? after;
      if (nearest == null ||
          target.difference(nearest.timestamp).abs() > _maximumSensorAge) {
        return null;
      }
      return nearest;
    }

    final totalMicros = after.timestamp
        .difference(before.timestamp)
        .inMicroseconds;
    if (totalMicros <= 0) return before;
    final ratio =
        target.difference(before.timestamp).inMicroseconds / totalMicros;
    return _TimedVector3(
      target,
      before.x + (after.x - before.x) * ratio,
      before.y + (after.y - before.y) * ratio,
      before.z + (after.z - before.z) * ratio,
    );
  }

  void _runInference() {
    final interpreter = _interpreter;
    if (interpreter == null) return;
    _inferenceRunning = true;
    try {
      final activityOutput = <List<double>>[
        List<double>.filled(_labels.length, 0),
      ];
      final fallOutput = <List<double>>[List<double>.filled(1, 0)];
      interpreter.runForMultipleInputs(
        <Object>[
          <List<List<double>>>[List<List<double>>.from(_window)],
        ],
        <int, Object>{
          _activityOutputOrdinal: activityOutput,
          _fallOutputOrdinal: fallOutput,
        },
      );

      final probabilities = activityOutput.first;
      final fallProbability = fallOutput.first.first;
      final activityFallProbability = probabilities[_fallIndex];
      final displayFallThreshold = math.max(
        _fallThreshold,
        _minimumFallDisplayProbability,
      );
      final decision = selectPrimaryActivity(
        labels: _labels,
        probabilities: probabilities,
        fallIndex: _fallIndex,
        fallProbability: fallProbability,
        fallThreshold: displayFallThreshold,
        minimumActivityFallConfidence: _minimumActivityFallConfidence,
      );

      final alertFallThreshold = math.max(
        _alertThreshold,
        _minimumFallAlertProbability,
      );
      final hasFallAgreement =
          fallProbability >= alertFallThreshold &&
          activityFallProbability >= _minimumActivityFallConfidence;
      _fallHistory.addLast(hasFallAgreement);
      while (_fallHistory.length > _fallVoteWindowCount) {
        _fallHistory.removeFirst();
      }
      final possibleFall =
          _fallHistory.where((value) => value).length >= _minimumFallVotes &&
          (_lastPossibleFall == null ||
              DateTime.now().difference(_lastPossibleFall!) >=
                  const Duration(seconds: 30));
      if (possibleFall) {
        _lastPossibleFall = DateTime.now();
        _fallHistory.clear();
      }

      _setSnapshot(
        ActivitySnapshot(
          label: decision.label,
          confidence: decision.confidence,
          fallProbability: fallProbability.clamp(0, 1),
          updatedAt: DateTime.now(),
          state: ActivityMonitorState.active,
          possibleFall: possibleFall || _snapshot.possibleFall,
          message: possibleFall
              ? 'Possible fall detected. Please confirm that you are safe.'
              : 'On-device monitoring is active.',
        ),
      );
      _hasRunInference = true;
      _samplesSinceInference = 0;
    } catch (error, stackTrace) {
      debugPrint('Activity inference failed: $error\n$stackTrace');
      _setSnapshot(
        const ActivitySnapshot(
          label: 'Monitoring unavailable',
          state: ActivityMonitorState.unavailable,
          message: 'The activity model could not process the sensor window.',
        ),
      );
    } finally {
      _inferenceRunning = false;
    }
  }

  void _handleSensorError(Object error, StackTrace stackTrace) {
    debugPrint('Motion sensor error: $error\n$stackTrace');
    _setSnapshot(
      const ActivitySnapshot(
        label: 'Sensor unavailable',
        state: ActivityMonitorState.unavailable,
        message: 'This device did not provide both required motion sensors.',
      ),
    );
  }

  @override
  void acknowledgePossibleFall() {
    if (!_snapshot.possibleFall) return;
    // The user explicitly confirmed that the previous event was safe. Remove
    // its rolling votes and cooldown so a separate future fall can be detected.
    _fallHistory.clear();
    _lastPossibleFall = null;
    _setSnapshot(
      ActivitySnapshot(
        label: _snapshot.label,
        confidence: _snapshot.confidence,
        fallProbability: _snapshot.fallProbability,
        updatedAt: _snapshot.updatedAt,
        state: _snapshot.state,
        message: 'Safety confirmed. Monitoring continues.',
      ),
    );
  }

  void _setSnapshot(ActivitySnapshot value) {
    _snapshot = value;
    notifyListeners();
  }

  Future<void> _releaseResources() async {
    _sampleTimer?.cancel();
    _sampleTimer = null;
    await _accelerometerSubscription?.cancel();
    await _gyroscopeSubscription?.cancel();
    _accelerometerSubscription = null;
    _gyroscopeSubscription = null;
    _interpreter?.close();
    _interpreter = null;
    _accelerometer.clear();
    _gyroscope.clear();
    _window.clear();
    _fallHistory.clear();
    _samplesSinceInference = 0;
    _hasRunInference = false;
    _inferenceRunning = false;
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    await _releaseResources();
    _setSnapshot(
      const ActivitySnapshot(
        label: 'Monitoring paused',
        state: ActivityMonitorState.stopped,
        message: 'Activity monitoring is currently paused.',
      ),
    );
  }

  @override
  void dispose() {
    _sampleTimer?.cancel();
    _accelerometerSubscription?.cancel();
    _gyroscopeSubscription?.cancel();
    _interpreter?.close();
    super.dispose();
  }
}

@immutable
class _TimedVector3 {
  const _TimedVector3(this.timestamp, this.x, this.y, this.z);

  final DateTime timestamp;
  final double x;
  final double y;
  final double z;
}
