import 'dart:math';

/// Precise coordinates exist only in memory until [blurLocation] returns.
class ExactReportLocation {
  const ExactReportLocation(this.latitude, this.longitude);

  final double latitude;
  final double longitude;
}

/// Coarsened location/time safe to place in a future report request.
class BlurredReportLocation {
  const BlurredReportLocation({
    required this.latitude,
    required this.longitude,
    required this.timeBucket,
  });

  final double latitude;
  final double longitude;
  final String timeBucket;

  Map<String, Object> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
    'time_bucket': timeBucket,
  };
}

/// On-device planar Laplace geo-noise with a 100 m expected radial offset.
/// The default random source is cryptographically secure; [random] is exposed
/// only to make unit tests deterministic.
class ReportLocationPrivacy {
  ReportLocationPrivacy({Random? random}) : _random = random ?? Random.secure();

  static const meanRadiusMeters = 100.0;
  static const _earthRadiusMeters = 6371008.8;
  static const _laplaceScaleMeters = meanRadiusMeters / 2;
  final Random _random;

  BlurredReportLocation blurLocation(
    ExactReportLocation exact,
    DateTime timestamp,
  ) {
    _validateCoordinates(exact.latitude, exact.longitude);
    final u1 = max(_random.nextDouble(), 1e-15);
    final u2 = max(_random.nextDouble(), 1e-15);
    final radius = -_laplaceScaleMeters * (log(u1) + log(u2));
    final bearing = 2 * pi * _random.nextDouble();
    final angularDistance = radius / _earthRadiusMeters;
    final latitude1 = exact.latitude * pi / 180;
    final longitude1 = exact.longitude * pi / 180;
    final latitude2 = asin(
      sin(latitude1) * cos(angularDistance) +
          cos(latitude1) * sin(angularDistance) * cos(bearing),
    );
    final longitude2 =
        longitude1 +
        atan2(
          sin(bearing) * sin(angularDistance) * cos(latitude1),
          cos(angularDistance) - sin(latitude1) * sin(latitude2),
        );
    return BlurredReportLocation(
      latitude: latitude2 * 180 / pi,
      longitude: _normalizeLongitude(longitude2 * 180 / pi),
      timeBucket: formatTwoHourBucket(timestamp),
    );
  }

  static String formatTwoHourBucket(DateTime timestamp) {
    final local = timestamp.toLocal();
    final startHour = (local.hour ~/ 2) * 2;
    final endHour = startHour + 2;
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final start = _hour(startHour);
    final end = _hour(endHour);
    final range = start.period == end.period
        ? '${start.value}–${end.value} ${end.period}'
        : '${start.value} ${start.period}–${end.value} ${end.period}';
    return '${weekdays[local.weekday - 1]} $range';
  }

  static ({int value, String period}) _hour(int hour) {
    final normalized = hour % 24;
    final label = normalized % 12 == 0 ? 12 : normalized % 12;
    final period = normalized < 12 ? 'am' : 'pm';
    return (value: label, period: period);
  }

  static double _normalizeLongitude(double longitude) {
    final normalized = (longitude + 540) % 360 - 180;
    return normalized == -180 && longitude > 0 ? 180 : normalized;
  }

  static void _validateCoordinates(double latitude, double longitude) {
    if (!latitude.isFinite || latitude < -90 || latitude > 90) {
      throw ArgumentError.value(latitude, 'latitude');
    }
    if (!longitude.isFinite || longitude < -180 || longitude > 180) {
      throw ArgumentError.value(longitude, 'longitude');
    }
  }
}

/// Whitelisted conditions deliberately avoid a free-text field that could
/// expose names, phone numbers, or vehicle plates.
enum ReportCondition {
  poorLighting('Poor street lighting'),
  brokenFootpath('Broken or blocked footpath'),
  poorVisibility('Poor visibility'),
  isolatedArea('Isolated or unmonitored area'),
  otherHazard('Other physical hazard');

  const ReportCondition(this.label);
  final String label;
}

class AnonymousReportPreview {
  const AnonymousReportPreview({
    required this.condition,
    required this.location,
  });

  final ReportCondition condition;
  final BlurredReportLocation location;

  Map<String, Object> toJson() => {
    'condition': condition.name,
    ...location.toJson(),
  };
}
