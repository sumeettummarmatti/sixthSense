import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sixthsense_app/core/routes/safe_routes.dart';

Map<String, Object> _route(String kind, int extra) => {
  'kind': kind,
  'points': [
    [12.9719, 77.6412],
    [12.9665, 77.6400],
    [12.9610, 77.6390],
  ],
  'distance_m': 1908 + extra,
  'duration_s': 1374 + extra,
  'extra_m': extra,
  'extra_s': extra,
  'score': 0.6,
  'support': 0.6,
  'concern': 0.0,
  'coverage': 1.0,
  'evidence': 'Insufficient data',
  'counts': {'lamp': 8},
  'facts': ['8 streetlights'],
  'why': extra == 0 ? ['shortest route'] : ['+1 min', '8 streetlights vs 1'],
};

void main() {
  group('route geometry', () {
    const line = [(12.9700, 77.6400), (12.9700, 77.6500)]; // ~1.08 km east-west

    test('a point on the route is ~0 m away', () {
      expect(distanceToRoute(12.9700, 77.6450, line), lessThan(1));
    });

    test('a point ~200 m north of the route is ~200 m away', () {
      expect(distanceToRoute(12.9718, 77.6450, line), closeTo(200, 5));
    });

    test('past the end it measures to the end point', () {
      expect(distanceToRoute(12.9700, 77.6520, line), closeTo(217, 5));
    });
  });

  group('off-route nudge', () {
    const line = [(12.9700, 77.6400), (12.9700, 77.6500)];
    final t0 = DateTime(2026, 11, 14, 22);

    test('nudges once after a minute well off the route, then stays quiet', () {
      final watch = OffRouteWatch(line);
      expect(watch.update(12.9720, 77.645, t0), isFalse); // 220 m off, just now
      expect(
        watch.update(12.9720, 77.645, t0.add(const Duration(seconds: 61))),
        isTrue,
      );
      expect(
        watch.update(12.9720, 77.645, t0.add(const Duration(minutes: 3))),
        isFalse,
        reason: 'quiet for 5 minutes after a nudge',
      );
      expect(
        watch.update(12.9720, 77.645, t0.add(const Duration(minutes: 7))),
        isTrue,
      );
    });

    test('walking near the route, or briefly off it, never nudges', () {
      final watch = OffRouteWatch(line);
      for (var s = 0; s < 600; s += 10) {
        // Alternates 50 m and 200 m off every 30 s.
        final lat = (s ~/ 30).isEven ? 12.97045 : 12.9718;
        expect(
          watch.update(lat, 77.645, t0.add(Duration(seconds: s))),
          isFalse,
        );
      }
    });
  });

  group('safe routes client', () {
    late HttpServer server;
    late List<HttpRequest> seen;
    var status = 200;
    Object body = {};

    setUp(() async {
      seen = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        seen.add(request);
        request.response
          ..statusCode = status
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(body));
        await request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    SafeRoutesApi api() =>
        SafeRoutesApi(baseUri: Uri.parse('http://127.0.0.1:${server.port}'));

    test('parses ranked routes and sends no identity', () async {
      status = 200;
      body = {
        'area': 'indiranagar',
        'time_band': 'night',
        'shortest': 0,
        'recommended': 1,
        'routes': [_route('shortest', 0), _route('recommended', 245)],
        'note': 'No route is labelled safe.',
      };
      final routes = await api().routes(
        fromLat: 12.97191234,
        fromLon: 77.64121234,
        toLat: 12.961,
        toLon: 77.639,
      );
      expect(routes.timeBand, 'night');
      final recommended = routes.routes[routes.recommended];
      expect(recommended.extraMeters, 245);
      expect(recommended.why, contains('8 streetlights vs 1'));
      expect(recommended.points.first, (12.9719, 77.6412));
      expect(recommended.summary, contains('+4 min'));

      final request = seen.single;
      expect(request.uri.path, '/routes');
      // Rounded to ~1 m; nothing else about the person.
      expect(request.uri.queryParameters['from'], '12.97191,77.64121');
      expect(request.headers.value('authorization'), isNull);
      expect(request.headers.value('cookie'), isNull);
    });

    test('outside the data area says so', () async {
      status = 422;
      body = {'detail': 'outside_area'};
      await expectLater(
        api().routes(
          fromLat: 12.88,
          fromLon: 77.57,
          toLat: 12.89,
          toLon: 77.58,
        ),
        throwsA(
          isA<RoutesUnavailable>().having(
            (e) => e.reason,
            'reason',
            'outside_area',
          ),
        ),
      );
    });

    test('a server that is down is reported, not thrown raw', () async {
      final down = api(); // port read before closing
      await server.close(force: true);
      await expectLater(
        down.routes(fromLat: 12.97, fromLon: 77.64, toLat: 12.96, toLon: 77.63),
        throwsA(
          isA<RoutesUnavailable>().having(
            (e) => e.reason,
            'reason',
            'unreachable',
          ),
        ),
      );
    });

    test('defaults to the Core API host on port 8001', () {
      expect(const SafeRoutesApi().base.port, 8001);
    });
  });
}
