import 'dart:convert';
import 'dart:io';

import 'package:maplibre_gl/maplibre_gl.dart';

import 'geo.dart';

/// A walking route between two points, from the free OSRM foot router run by
/// FOSSGIS (routing.openstreetmap.de). Only the helper's phone asks for one,
/// and only while going to someone who asked for help; the request carries
/// two points and nothing else. Swap for our own Valhalla before the pilot.
class WalkRoute {
  const WalkRoute(this.points, this.meters, this.seconds);

  final List<LatLng> points;
  final double meters;
  final double seconds;

  int get minutes => (seconds / 60).ceil().clamp(1, 999);
}

class WalkRouter {
  WalkRouter();

  WalkRoute? _last;
  LatLng? _lastFrom;
  LatLng? _lastTo;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _busy = false;

  /// The route, refreshed when either end moved 30 m or every 20 s.
  Future<WalkRoute?> route(LatLng from, LatLng to) async {
    final fresh =
        _last != null &&
        _lastFrom != null &&
        _lastTo != null &&
        DateTime.now().difference(_lastAt) < const Duration(seconds: 20) &&
        _moved(from, _lastFrom!) < 30 &&
        _moved(to, _lastTo!) < 30;
    if (fresh || _busy || !mapsEnabled) return _last;
    _busy = true;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final uri = Uri.https(
        'routing.openstreetmap.de',
        '/routed-foot/route/v1/foot/'
            '${from.longitude},${from.latitude};${to.longitude},${to.latitude}',
        {'overview': 'full', 'geometries': 'geojson'},
      );
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'SixthSense-pilot/0.1');
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      final body = jsonDecode(await utf8.decoder.bind(response).join()) as Map;
      final routes = body['routes'] as List? ?? const [];
      if (routes.isEmpty) return _last;
      final first = routes.first as Map;
      final coords = (first['geometry'] as Map)['coordinates'] as List;
      _last = WalkRoute(
        [
          for (final c in coords.cast<List>())
            LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
        ],
        (first['distance'] as num).toDouble(),
        (first['duration'] as num).toDouble(),
      );
      _lastFrom = from;
      _lastTo = to;
      _lastAt = DateTime.now();
      return _last;
    } catch (_) {
      return _last; // offline or busy: keep the old line, fall back to straight
    } finally {
      _busy = false;
      client.close(force: true);
    }
  }

  static double _moved(LatLng a, LatLng b) =>
      distanceMeters(a.latitude, a.longitude, b.latitude, b.longitude);
}
