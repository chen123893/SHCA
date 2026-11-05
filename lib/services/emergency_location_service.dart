import 'package:flutter/services.dart';

class EmergencyLocationService {
  static const channel = MethodChannel('com.shca.shca/emergency_location');

  static Future<Map<String, dynamic>?> capture() async {
    try {
      return await channel.invokeMapMethod<String, dynamic>('capture');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

/// Coordinates and capture time from an alert, including alerts from older apps.
class AlertLocation {
  const AlertLocation(
    this.latitude,
    this.longitude,
    this.recordedAt,
    this.accuracyMeters,
    this.source,
    this.lastKnown,
  );

  final double latitude;
  final double longitude;
  final DateTime recordedAt;
  final double accuracyMeters;
  final String source;
  final bool lastKnown;

  static AlertLocation? parse(Object? value) {
    if (value is! Map) return null;
    final lat = value['latitude'];
    final lng = value['longitude'];
    final time = value['recordedAt'];
    final accuracy = value['accuracyMeters'];
    if (lat is! num ||
        !lat.isFinite ||
        lat < -90 ||
        lat > 90 ||
        lng is! num ||
        !lng.isFinite ||
        lng < -180 ||
        lng > 180 ||
        time is! num ||
        !time.isFinite ||
        time != time.truncateToDouble() ||
        time <= 0 ||
        time > 8640000000000000 ||
        accuracy is! num ||
        !accuracy.isFinite ||
        accuracy < 0 ||
        accuracy > 100000 ||
        !const ['phone', 'watch'].contains(value['source']) ||
        !const ['current', 'last_known'].contains(value['kind'])) {
      return null;
    }
    return AlertLocation(
      lat.toDouble(),
      lng.toDouble(),
      DateTime.fromMillisecondsSinceEpoch(time.toInt()),
      accuracy.toDouble(),
      value['source'] as String,
      value['kind'] == 'last_known',
    );
  }

  Uri get mapsUri => Uri.https('www.google.com', '/maps/search/', {
    'api': '1',
    'query': '$latitude,$longitude',
  });
}
