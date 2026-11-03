import 'dart:math' as math;

/// A conservative runtime confirmation, not an additional trained classifier.
/// Uses the same ordered SI-unit samples as the wrist model. A wrist flick
/// alone is insufficient: an impact must be followed by a settled period and
/// either a changed resting orientation or sustained unloading before impact.
bool confirmsWristFall(List<List<double>> samples, List<String> features) {
  if (samples.length < 100) return false;
  final ai = features.indexOf('acc_magnitude_m_s2');
  final gi = features.indexOf('gyro_magnitude_rad_s');
  final axes = [
    'acc_x_m_s2',
    'acc_y_m_s2',
    'acc_z_m_s2',
  ].map(features.indexOf).toList();
  if (ai < 0 || gi < 0 || axes.any((i) => i < 0)) return false;
  var peak = 0;
  for (var i = 1; i < samples.length; i++) {
    if (samples[i][ai] > samples[peak][ai]) peak = i;
  }
  // At least 0.4 s before impact and 0.3 s settling + 0.9 s afterwards.
  if (peak < 20 || samples.length - peak < 60 || samples[peak][ai] < 18) {
    return false;
  }
  final tail = samples.sublist(samples.length - 45);
  final meanAcc = tail.fold(0.0, (s, r) => s + r[ai]) / tail.length;
  final variance =
      tail.fold(0.0, (s, r) => s + math.pow(r[ai] - meanAcc, 2)) / tail.length;
  final quiet = tail
      .where((r) => r[gi] < 1.2 && (r[ai] - 9.81).abs() < 2.5)
      .length;
  if (quiet < 40 || variance > 1.4 * 1.4) return false;
  // Repeated large swings/impacts indicate continuing exercise.
  var impacts = 0;
  var lastImpact = -20;
  for (var i = math.max(0, peak - 100); i < samples.length; i++) {
    if (samples[i][ai] >= 18 && i - lastImpact >= 15) {
      impacts++;
      lastImpact = i;
    }
  }
  if (impacts >= 3) return false;
  List<double> average(List<List<double>> rows) => axes
      .map(
        (axis) => rows.fold(0.0, (sum, row) => sum + row[axis]) / rows.length,
      )
      .toList();
  final before = average(samples.sublist(math.max(0, peak - 30), peak - 5));
  final after = average(tail);
  double norm(List<double> v) => math.sqrt(v.fold(0.0, (s, x) => s + x * x));
  final product = norm(before) * norm(after);
  if (product < 1) return false;
  final dot = List.generate(
    3,
    (i) => before[i] * after[i],
  ).reduce((a, b) => a + b);
  final angle = math.acos((dot / product).clamp(-1.0, 1.0)) * 180 / math.pi;
  var unloading = 0;
  var longestUnloading = 0;
  for (var i = math.max(0, peak - 25); i < peak; i++) {
    unloading = samples[i][ai] < 6 ? unloading + 1 : 0;
    longestUnloading = math.max(longestUnloading, unloading);
  }
  return angle >= 40 || longestUnloading >= 5;
}
