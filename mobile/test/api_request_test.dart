import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sixthsense_app/core/api/device_identity.dart';

class _SignedInIdentity extends DeviceIdentity {
  const _SignedInIdentity();

  @override
  Future<String?> accessToken() async => 'test-token';
}

void main() {
  test(
    'signed-in request with a body sends both the token and the body',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      String? auth;
      Object? body;
      server.listen((request) async {
        auth = request.headers.value(HttpHeaders.authorizationHeader);
        body = jsonDecode(await utf8.decoder.bind(request).join());
        request.response
          ..statusCode = 201
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'contact_link_id': 'c1',
              'invite_token': 't1',
              'invite_url': 'https://sixthsense.app/invite#t1',
            }),
          );
        await request.response.close();
      });

      final api = DemoApi(
        identity: const _SignedInIdentity(),
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      final invite = await api.createInvite('Priya');
      await server.close(force: true);

      expect(invite['invite_token'], 't1');
      expect(auth, 'Bearer test-token');
      expect(body, {'owner_label': 'Priya'});
    },
  );

  test('starting a journey ends a leftover open journey and retries', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final calls = <String>[];
    var open = true;
    Map<String, Object?> journey(String id) => {
      'id': id,
      'state': 'active',
      'next_check_in_at': '2026-11-12T18:00:00Z',
      'timers': {'heartbeat_timeout_min': 10},
    };
    server.listen((request) async {
      await utf8.decoder.bind(request).join();
      final call = '${request.method} ${request.uri.path}';
      calls.add(call);
      Object? reply;
      var status = 200;
      if (call == 'POST /journeys' && open) {
        status = 409;
        reply = {'detail': 'journey_already_open'};
      } else if (call == 'POST /journeys') {
        status = 201;
        reply = journey('new');
      } else if (call == 'GET /journeys/current') {
        reply = journey('old');
      } else if (call == 'POST /journeys/old/end') {
        open = false;
        reply = journey('old');
      }
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(reply));
      await request.response.close();
    });

    final api = DemoApi(
      identity: const _SignedInIdentity(),
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
    );
    final started = await api.startJourney(5);
    await server.close(force: true);

    expect(started.id, 'new');
    expect(calls, [
      'POST /journeys',
      'GET /journeys/current',
      'POST /journeys/old/end',
      'POST /journeys',
    ]);
  });
}
