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
  test('signed-in request with a body sends both the token and the body',
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
        ..write(jsonEncode({
          'contact_link_id': 'c1',
          'invite_token': 't1',
          'invite_url': 'https://sixthsense.app/invite#t1',
        }));
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
  });
}
