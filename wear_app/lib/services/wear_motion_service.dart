import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'wrist_fall_confirmation.dart';

enum MotionState { starting, collecting, active, unavailable, stopped }

@immutable
class MotionSnapshot {
  const MotionSnapshot({
    this.label = 'Preparing sensors',
    this.confidence = 0,
    this.fallProbability = 0,
    this.updatedAt,
    this.state = MotionState.starting,
    this.possibleFall = false,
    this.message = 'Loading the wrist model…',
  });

  final String label;
  final double confidence;
  final double fallProbability;
  final DateTime? updatedAt;
  final MotionState state;
  final bool possibleFall;
  final String message;
}

@immutable
class WristImpactEvidence {
  const WristImpactEvidence({
    required this.peakAcceleration,
    required this.accelerationRange,
    required this.peakJerk,
    required this.peakAngularSpeed,
  });

  final double peakAcceleration;
  final double accelerationRange;
  final double peakJerk;
  final double peakAngularSpeed;

  bool passes({
    required double minimumPeakAcceleration,
    required double minimumAccelerationRange,
    required double minimumPeakJerk,
    required double minimumPeakAngularSpeed,
  }) =>
      peakAcceleration >= minimumPeakAcceleration &&
      accelerationRange >= minimumAccelerationRange &&
      peakJerk >= minimumPeakJerk &&
      peakAngularSpeed >= minimumPeakAngularSpeed;
}

@visibleForTesting
WristImpactEvidence evaluateWristImpact({
  required List<double> accelerationMagnitudes,
  required List<double> angularSpeedMagnitudes,
  double samplePeriodSeconds = 0.02,
}) {
  if (accelerationMagnitudes.length < 2 ||
      accelerationMagnitudes.length != angularSpeedMagnitudes.length ||
      samplePeriodSeconds <= 0) {
    throw ArgumentError('A synchronized wrist sensor window is required.');
  }
  var minimumAcceleration = accelerationMagnitudes.first;
  var peakAcceleration = accelerationMagnitudes.first;
  var peakAngularSpeed = angularSpeedMagnitudes.first;
  var peakJerk = 0.0;
  for (var index = 0; index < accelerationMagnitudes.length; index++) {
    final acceleration = accelerationMagnitudes[index];
    minimumAcceleration = math.min(minimumAcceleration, acceleration);
    peakAcceleration = math.max(peakAcceleration, acceleration);
    peakAngularSpeed = math.max(
      peakAngularSpeed,
      angularSpeedMagnitudes[index],
    );
    if (index > 0) {
      peakJerk = math.max(
        peakJerk,
        (acceleration - accelerationMagnitudes[index - 1]).abs() /
            samplePeriodSeconds,
      );
    }
  }
  return WristImpactEvidence(
    peakAcceleration: peakAcceleration,
    accelerationRange: peakAcceleration - minimumAcceleration,
    peakJerk: peakJerk,
    peakAngularSpeed: peakAngularSpeed,
  );
}

/// Reads Wear OS motion sensors at a requested 50 Hz and runs the wrist TFLite
/// model locally. Raw samples never leave the watch.
class WearMotionService extends ChangeNotifier {
  static const _modelAsset =
      'assets/models/wearable/activity_fall_model.tflite';
  static const _scalerAsset = 'assets/models/wearable/scaler.json';
  static const _metadataAsset = 'assets/models/wearable/metadata.json';
  static const _samplePeriod = Duration(milliseconds: 20);
  static const _maximumSensorAge = Duration(milliseconds: 300);
  static const _minimumActivityConfidence = 0.35;
  static const _minimumActivityFallConfidence = 0.55;

  final List<List<double>> _window = <List<double>>[];
  final List<List<double>> _rawWindow = <List<double>>[];
  final List<List<double>> _confirmationWindow = <List<double>>[];
  DateTime? _lastSampleAt;
  final Queue<bool> _fallVotes = Queue<bool>();

  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;
  StreamSubscription<GyroscopeEvent>? _gyroscopeSubscription;
  Timer? _sampleTimer;
  Interpreter? _interpreter;
  _TimedVector3? _latestAccelerometer;
  _TimedVector3? _latestGyroscope;

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
  int _lastReportedProgress = 0;
  int _minimumPositiveWindows = 2;
  int _rollingWindowCount = 3;
  Duration _alertCooldown = const Duration(seconds: 30);
  bool _hasRunInference = false;
  bool _inferenceRunning = false;
  bool _started = false;
  Future<void> _operations = Future<void>.value();
  double _alertThreshold = 0.8;
  double _minimumPeakAcceleration = 18.0;
  double _minimumAccelerationRange = 12.0;
  double _minimumPeakJerk = 350.0;
  double _minimumPeakAngularSpeed = 2.5;
  DateTime? _lastPossibleFall;
  bool _disposed = false;
  MotionSnapshot _snapshot = const MotionSnapshot();

  MotionSnapshot get snapshot => _snapshot;

  Future<void> start() {
    _operations = _operations.then((_) => _start());
    return _operations;
  }

  Future<void> _start() async {
    if (_started) return;
    _started = true;
    _setSnapshot(const MotionSnapshot());
    try {
      await _loadModelContract();
      _accelerometerSubscription =
          accelerometerEventStream(samplingPeriod: _samplePeriod).listen(
            (event) => _latestAccelerometer = _TimedVector3(
              DateTime.now(),
              event.x,
              event.y,
              event.z,
            ),
            onError: _handleSensorError,
          );
      _gyroscopeSubscription =
          gyroscopeEventStream(samplingPeriod: _samplePeriod).listen(
            (event) => _latestGyroscope = _TimedVector3(
              DateTime.now(),
              event.x,
              event.y,
              event.z,
            ),
            onError: _handleSensorError,
          );
      _sampleTimer = Timer.periodic(_samplePeriod, (_) => _sampleOnGrid());
      _setSnapshot(
        const MotionSnapshot(
          label: 'Collecting movement',
          state: MotionState.collecting,
          message: 'Wear the watch snugly and move normally.',
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Unable to start wrist monitoring: $error\n$stackTrace');
      await _stop();
      _setSnapshot(
        const MotionSnapshot(
          label: 'Monitoring unavailable',
          state: MotionState.unavailable,
          message: 'The watch sensors or model could not be opened.',
        ),
      );
    }
  }

  Future<void> _loadModelContract() async {
    final scaler = jsonDecode(
      await rootBundle.loadString(_scalerAsset),
    ) as Map<String, dynamic>;
    final metadata = jsonDecode(
      await rootBundle.loadString(_metadataAsset),
    ) as Map<String, dynamic>;
    final policy = metadata['recommended_alert_policy'] as Map<String, dynamic>;
    final physicalGate =
        metadata['runtime_physical_gate'] as Map<String, dynamic>?;
    _labels = (metadata['labels'] as List<dynamic>).cast<String>();
    _featureNames = (metadata['feature_names'] as List<dynamic>).cast<String>();
    final scalerFeatures = (scaler['feature_names'] as List<dynamic>)
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
    _alertThreshold = (policy['threshold'] as num).toDouble();
    _minimumPositiveWindows = (policy['minimum_positive_windows'] as num)
        .toInt();
    _rollingWindowCount = (policy['rolling_window_count'] as num).toInt();
    _alertCooldown = Duration(
      seconds: (policy['alert_cooldown_seconds'] as num).toInt(),
    );
    _minimumPeakAcceleration =
        (physicalGate?['minimum_peak_acceleration_m_s2'] as num?)?.toDouble() ??
        18.0;
    _minimumAccelerationRange =
        (physicalGate?['minimum_acceleration_range_m_s2'] as num?)
            ?.toDouble() ??
        12.0;
    _minimumPeakJerk =
        (physicalGate?['minimum_peak_jerk_m_s3'] as num?)?.toDouble() ?? 350.0;
    _minimumPeakAngularSpeed =
        (physicalGate?['minimum_peak_angular_speed_rad_s'] as num?)
            ?.toDouble() ??
        2.5;
    if (!listEquals(_featureNames, scalerFeatures) ||
        _mean.length != _featureNames.length ||
        _scale.length != _featureNames.length ||
        !_featureNames.contains('acc_magnitude_m_s2') ||
        !_featureNames.contains('gyro_magnitude_rad_s') ||
        _windowSize != 128) {
      throw const FormatException('Invalid wearable model contract.');
    }
    _interpreter = await Interpreter.fromAsset(_modelAsset);
    final inputShape = _interpreter!.getInputTensor(0).shape;
    if (!listEquals(inputShape, <int>[1, _windowSize, _featureNames.length])) {
      throw StateError('Unexpected model input: $inputShape');
    }
    for (
      var ordinal = 0;
      ordinal < _interpreter!.getOutputTensors().length;
      ordinal++
    ) {
      final shape = _interpreter!.getOutputTensor(ordinal).shape;
      if (listEquals(shape, <int>[1, _labels.length])) {
        _activityOutputOrdinal = ordinal;
      } else if (listEquals(shape, const <int>[1, 1])) {
        _fallOutputOrdinal = ordinal;
      }
    }
    if (_activityOutputOrdinal < 0 || _fallOutputOrdinal < 0) {
      throw StateError('Activity/fall outputs were not found.');
    }
  }

  void _sampleOnGrid() {
    if (!_started) return;
    final now = DateTime.now();
    final acc = _latestAccelerometer;
    final gyro = _latestGyroscope;
    if (acc == null || gyro == null) return;
    if (now.difference(acc.timestamp) > _maximumSensorAge ||
        now.difference(gyro.timestamp) > _maximumSensorAge) {
      _resetSamplingWindow();
      return;
    }
    if (_lastSampleAt != null &&
        now.difference(_lastSampleAt!) > const Duration(milliseconds: 200)) {
      _resetSamplingWindow();
    }
    _lastSampleAt = now;
    final available = <String, double>{
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
        .map((feature) => available[feature]!)
        .toList(growable: false);
    _rawWindow.add(raw);
    _confirmationWindow.add(raw);
    if (_confirmationWindow.length > 250) _confirmationWindow.removeAt(0);
    _window.add(
      List<double>.generate(
        raw.length,
        (index) => (raw[index] - _mean[index]) / _scale[index],
        growable: false,
      ),
    );
    if (_window.length > _windowSize) {
      _window.removeAt(0);
      _rawWindow.removeAt(0);
    }
    if (!_hasRunInference) {
      final progress = ((_window.length / _windowSize) * 100).floor();
      final progressStep = (progress ~/ 20) * 20;
      if (progressStep > _lastReportedProgress) {
        _lastReportedProgress = progressStep;
        _setSnapshot(
          MotionSnapshot(
            label: 'Starting monitoring',
            state: MotionState.collecting,
            message: 'Preparing activity detection • $progress%',
          ),
        );
      }
    }
    _samplesSinceInference++;
    if (_window.length == _windowSize &&
        (!_hasRunInference || _samplesSinceInference >= _stepSize) &&
        !_inferenceRunning) {
      _runInference();
    }
  }

  void _runInference() {
    final interpreter = _interpreter;
    if (interpreter == null) return;
    _inferenceRunning = true;
    try {
      final activity = <List<double>>[List<double>.filled(_labels.length, 0)];
      final fall = <List<double>>[List<double>.filled(1, 0)];
      interpreter.runForMultipleInputs(
        <Object>[
          <List<List<double>>>[List<List<double>>.from(_window)],
        ],
        <int, Object>{
          _activityOutputOrdinal: activity,
          _fallOutputOrdinal: fall,
        },
      );
      final probabilities = activity.first;
      final fallProbability = fall.first.first.clamp(0.0, 1.0);
      final accelerationIndex = _featureNames.indexOf('acc_magnitude_m_s2');
      final angularSpeedIndex = _featureNames.indexOf('gyro_magnitude_rad_s');
      final impact = evaluateWristImpact(
        accelerationMagnitudes: _rawWindow
            .map((row) => row[accelerationIndex])
            .toList(growable: false),
        angularSpeedMagnitudes: _rawWindow
            .map((row) => row[angularSpeedIndex])
            .toList(growable: false),
      );
      final modelAgreement =
          fallProbability >= _alertThreshold &&
          probabilities[_fallIndex] >= _minimumActivityFallConfidence;
      final agreement =
          modelAgreement &&
          impact.passes(
            minimumPeakAcceleration: _minimumPeakAcceleration,
            minimumAccelerationRange: _minimumAccelerationRange,
            minimumPeakJerk: _minimumPeakJerk,
            minimumPeakAngularSpeed: _minimumPeakAngularSpeed,
          );
      if (modelAgreement && !agreement) {
        debugPrint(
          'Rejected wrist fall without physical impact: '
          'acc=${impact.peakAcceleration.toStringAsFixed(1)}, '
          'range=${impact.accelerationRange.toStringAsFixed(1)}, '
          'jerk=${impact.peakJerk.toStringAsFixed(0)}, '
          'gyro=${impact.peakAngularSpeed.toStringAsFixed(1)}',
        );
      }
      _fallVotes.addLast(agreement);
      while (_fallVotes.length > _rollingWindowCount) {
        _fallVotes.removeFirst();
      }
      final possibleFall =
          _fallVotes.where((vote) => vote).length >= _minimumPositiveWindows &&
          confirmsWristFall(_confirmationWindow, _featureNames) &&
          (_lastPossibleFall == null ||
              DateTime.now().difference(_lastPossibleFall!) >= _alertCooldown);
      if (possibleFall) {
        _lastPossibleFall = DateTime.now();
        _fallVotes.clear();
      }
      var bestIndex = -1;
      var bestProbability = -1.0;
      for (var index = 0; index < probabilities.length; index++) {
        if (index == _fallIndex) continue;
        if (probabilities[index] > bestProbability) {
          bestIndex = index;
          bestProbability = probabilities[index];
        }
      }
      final activeFall = possibleFall || _snapshot.possibleFall;
      final label = activeFall
          ? 'Possible fall'
          : _displayLabel(_labels[bestIndex], bestProbability);
      _setSnapshot(
        MotionSnapshot(
          label: label,
          confidence: activeFall ? fallProbability : bestProbability,
          fallProbability: fallProbability,
          updatedAt: DateTime.now(),
          state: MotionState.active,
          possibleFall: activeFall,
          message: possibleFall
              ? 'Possible fall detected. Please confirm your safety.'
              : 'Wrist monitoring is active.',
        ),
      );
      _hasRunInference = true;
      _samplesSinceInference = 0;
      debugPrint(
        'Wearable inference active: $label, '
        '${(activeFall ? fallProbability : bestProbability).toStringAsFixed(2)}',
      );
    } catch (error, stackTrace) {
      debugPrint('Wearable inference failed: $error\n$stackTrace');
      _setSnapshot(
        const MotionSnapshot(
          label: 'Monitoring unavailable',
          state: MotionState.unavailable,
          message: 'The model could not process this sensor window.',
        ),
      );
    } finally {
      _inferenceRunning = false;
    }
  }

  String _displayLabel(String label, double confidence) {
    if (confidence < _minimumActivityConfidence) return 'Checking movement';
    return switch (label) {
      'walking' => 'Walking',
      'running' => 'Running',
      'chair_transition' => 'Sitting or standing',
      'crouching' => 'Bending down',
      'stumble' => 'Unsteady movement',
      'jumping' => 'Exercise movement',
      'hand_activity' => 'Light activity',
      _ => 'Checking movement',
    };
  }

  void acknowledgePossibleFall() {
    _fallVotes.clear();
    _lastPossibleFall = DateTime.now();
    _confirmationWindow.clear();
    _setSnapshot(
      MotionSnapshot(
        label: _snapshot.label == 'Possible fall'
            ? 'Checking movement'
            : _snapshot.label,
        confidence: _snapshot.confidence,
        fallProbability: _snapshot.fallProbability,
        updatedAt: _snapshot.updatedAt,
        state: _snapshot.state,
        message: 'Safety confirmed. Monitoring continues.',
      ),
    );
  }

  void _handleSensorError(Object error, StackTrace stackTrace) {
    debugPrint('Watch sensor error: $error\n$stackTrace');
    _setSnapshot(
      const MotionSnapshot(
        label: 'Sensors unavailable',
        state: MotionState.unavailable,
        message: 'This watch did not provide both required motion sensors.',
      ),
    );
  }

  void _resetSamplingWindow() {
    _window.clear();
    _rawWindow.clear();
    _confirmationWindow.clear();
    _fallVotes.clear();
    _samplesSinceInference = 0;
    _hasRunInference = false;
    _lastReportedProgress = 0;
    _lastSampleAt = null;
  }

  void _setSnapshot(MotionSnapshot snapshot) {
    _snapshot = snapshot;
    if (!_disposed) notifyListeners();
  }

  Future<void> stop() {
    _operations = _operations.then((_) => _stop());
    return _operations;
  }

  Future<void> _stop() async {
    _started = false;
    _sampleTimer?.cancel();
    await _accelerometerSubscription?.cancel();
    await _gyroscopeSubscription?.cancel();
    _interpreter?.close();
    _sampleTimer = null;
    _accelerometerSubscription = null;
    _gyroscopeSubscription = null;
    _interpreter = null;
    _latestAccelerometer = null;
    _latestGyroscope = null;
    _window.clear();
    _rawWindow.clear();
    _confirmationWindow.clear();
    _lastSampleAt = null;
    _fallVotes.clear();
    _samplesSinceInference = 0;
    _lastReportedProgress = 0;
    _hasRunInference = false;
    _setSnapshot(
      const MotionSnapshot(
        label: 'Fall detection off',
        state: MotionState.stopped,
        message: 'Turn on fall detection to monitor your wrist.',
      ),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
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
