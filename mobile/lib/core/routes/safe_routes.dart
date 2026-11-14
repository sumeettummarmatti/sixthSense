import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../location/geo.dart';

/// One walking route from the Insight zone's ranking (P4-W1-demo-safe-routes).
@immutable
class RankedRoute {
  const RankedRoute({
    required this.kind,
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.extraMeters,
    required this.extraSeconds,
    required this.evidence,
    required this.coverage,
    required this.facts,
    required this.why,
  });

  factory RankedRoute.fromJson(Map<String, dynamic> json) => RankedRoute(
    kind: json['kind'] as String,
    points: [
      for (final point in (json['points'] as List).cast<List>())
        ((point[0] as num).toDouble(), (point[1] as num).toDouble()),
    ],
    distanceMeters: (json['distance_m'] as num).toInt(),
    durationSeconds: (json['duration_s'] as num).toInt(),
    extraMeters: (json['extra_m'] as num).toInt(),
    extraSeconds: (json['extra_s'] as num).toInt(),
    evidence: json['evidence'] as String,
    coverage: (json['coverage'] as num).toDouble(),
    facts: [for (final fact in json['facts'] as List) '$fact'],
    why: [for (final reason in json['why'] as List) '$reason'],
  );

  /// `recommended`, `shortest` or `alternative`.
  final String kind;

  /// (lat, lon) pairs. Kept on this phone only; never sent to the Core server.
  final List<(double, double)> points;
  final int distanceMeters;
  final int durationSeconds;
  final int extraMeters;
  final int extraSeconds;

  /// Only *Strong evidence of concern*, *Some reports of concern* or *Insufficient data*.
  final String evidence;
  final double coverage;
  final List<String> facts;
  final List<String> why;

  int get minutes => (durationSeconds / 60).ceil().clamp(1, 999);

  /// "2.2 km · 27 min · +1 min"
  String get summary => [
    distanceLabel(distanceMeters.toDouble()),
    '$minutes min',
    if (extraSeconds >= 30) '+${(extraSeconds / 60).round()} min',
  ].join(' · ');
}

@immutable
class RankedRoutes {
  const RankedRoutes({
    required this.area,
    required this.timeBand,
    required this.shortest,
    required this.recommended,
    required this.routes,
    required this.note,
  });

  factory RankedRoutes.fromJson(Map<String, dynamic> json) => RankedRoutes(
    area: json['area'] as String,
    timeBand: json['time_band'] as String,
    shortest: (json['shortest'] as num).toInt(),
    recommended: (json['recommended'] as num).toInt(),
    routes: [
      for (final route in json['routes'] as List)
        RankedRoute.fromJson(route as Map<String, dynamic>),
    ],
    note: json['note'] as String? ?? '',
  );

  final String area;

  /// `day`, `evening` or `night`.
  final String timeBand;
  final int shortest;
  final int recommended;
  final List<RankedRoute> routes;
  final String note;
}

/// Why no ranking came back.
class RoutesUnavailable implements Exception {
  const RoutesUnavailable(this.reason);

  /// `outside_area` (no data for this place yet) or `unreachable`.
  final String reason;
}

/// Ranked walking routes from the Insight service. Deliberately anonymous: no
/// token, no device id, nothing that links the request to an account (rule 4).
/// Start and destination go only in this request; the service never stores
/// or logs them.
class SafeRoutesApi {
  const SafeRoutesApi({this.baseUri, this.client});

  static const _configured = String.fromEnvironment('INSIGHT_BASE_URL');
  static const _apiBase = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  );

  final Uri? baseUri;
  final HttpClient? client;

  /// Same host as the Core API, port 8001, unless INSIGHT_BASE_URL is set.
  Uri get base {
    if (baseUri != null) return baseUri!;
    if (_configured.isNotEmpty) return Uri.parse(_configured);
    final api = Uri.parse(_apiBase);
    return api.replace(port: 8001, path: '');
  }

  Future<RankedRoutes> routes({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
  }) async {
    final http = client ?? HttpClient();
    http.connectionTimeout = const Duration(seconds: 10);
    try {
      final uri = base.replace(
        path: '/routes',
        queryParameters: {
          'from': '${fromLat.toStringAsFixed(5)},${fromLon.toStringAsFixed(5)}',
          'to': '${toLat.toStringAsFixed(5)},${toLon.toStringAsFixed(5)}',
        },
      );
      final request = await http.getUrl(uri);
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode == 200) {
        return RankedRoutes.fromJson(jsonDecode(body) as Map<String, dynamic>);
      }
      if (body.contains('outside_area')) {
        throw const RoutesUnavailable('outside_area');
      }
      throw const RoutesUnavailable('unreachable');
    } on RoutesUnavailable {
      rethrow;
    } catch (_) {
      throw const RoutesUnavailable('unreachable');
    } finally {
      if (client == null) http.close();
    }
  }
}

/// Shortest distance in metres from a point to a route (a polyline), using a
/// local flat projection, which is accurate enough over a few kilometres.
double distanceToRoute(double lat, double lon, List<(double, double)> route) {
  if (route.isEmpty) return double.infinity;
  if (route.length == 1) {
    return distanceMeters(lat, lon, route.first.$1, route.first.$2);
  }
  const earth = 6371000.0;
  final cosLat = cos(lat * pi / 180);
  (double, double) project((double, double) p) => (
    (p.$2 - lon) * pi / 180 * earth * cosLat,
    (p.$1 - lat) * pi / 180 * earth,
  );
  var best = double.infinity;
  for (var i = 0; i < route.length - 1; i++) {
    final a = project(route[i]);
    final b = project(route[i + 1]);
    final dx = b.$1 - a.$1;
    final dy = b.$2 - a.$2;
    final lengthSquared = dx * dx + dy * dy;
    final t = lengthSquared == 0
        ? 0.0
        : ((-a.$1 * dx - a.$2 * dy) / lengthSquared).clamp(0.0, 1.0);
    final x = a.$1 + t * dx;
    final y = a.$2 + t * dy;
    best = min(best, sqrt(x * x + y * y));
  }
  return best;
}

/// Watches positions during a journey and says when the traveller has been
/// well off their chosen route for a while (a gentle check-in nudge, never an
/// alarm by itself).
class OffRouteWatch {
  OffRouteWatch(
    this.route, {
    this.thresholdMeters = 150,
    this.after = const Duration(seconds: 60),
    this.quietFor = const Duration(minutes: 5),
  });

  final List<(double, double)> route;
  final double thresholdMeters;
  final Duration after;
  final Duration quietFor;
  DateTime? _offSince;
  DateTime? _lastNudge;

  /// True once per stretch when it is time to nudge.
  bool update(double lat, double lon, DateTime now) {
    if (distanceToRoute(lat, lon, route) <= thresholdMeters) {
      _offSince = null;
      return false;
    }
    _offSince ??= now;
    final quiet = _lastNudge != null && now.difference(_lastNudge!) < quietFor;
    if (!quiet && now.difference(_offSince!) >= after) {
      _lastNudge = now;
      return true;
    }
    return false;
  }
}
