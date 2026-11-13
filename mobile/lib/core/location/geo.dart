import 'dart:io';
import 'dart:math';

/// Small distance helpers for "280 m · ~4 min walk" labels.

const _walkMetersPerMinute = 75.0; // ~4.5 km/h

double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  const earth = 6371000.0;
  final p1 = lat1 * pi / 180, p2 = lat2 * pi / 180;
  final dp = (lat2 - lat1) * pi / 180, dl = (lng2 - lng1) * pi / 180;
  final h =
      sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2);
  return 2 * earth * asin(sqrt(h));
}

int walkMinutes(double meters) => max(
  1,
  (meters * 1.25 / _walkMetersPerMinute).ceil(),
); // streets aren't straight

String distanceLabel(double meters) {
  if (meters < 1000) return '${(meters / 10).round() * 10} m';
  return '${(meters / 1000).toStringAsFixed(1)} km';
}

String walkLabel(double meters) =>
    '${distanceLabel(meters)} · ~${walkMinutes(meters)} min walk';

/// Maps (platform views), GPS and place search are off in widget tests.
final bool mapsEnabled = !Platform.environment.containsKey('FLUTTER_TEST');
