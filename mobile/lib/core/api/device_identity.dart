import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android Keystore backed identity and session operations for the demo API.
class DeviceIdentity {
  const DeviceIdentity();

  static const _channel = MethodChannel('in.sixthsense/device_identity');

  Future<String> publicKey() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw UnsupportedError('Device-key sign-in is available on Android.');
    }
    return (await _channel.invokeMethod<String>('getDevicePublicKey'))!;
  }

  Future<String> signChallenge(String deviceId, String nonce) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw UnsupportedError('Device-key sign-in is available on Android.');
    }
    return (await _channel.invokeMethod<String>('signDeviceChallenge', {
      'deviceId': deviceId,
      'nonce': nonce,
    }))!;
  }

  Future<String?> deviceId() async => _read('getDeviceId');
  Future<String?> accessToken() async => _read('getAccessToken');

  Future<void> saveSession({
    required String deviceId,
    required String accountId,
    required String accessToken,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('saveSession', {
      'deviceId': deviceId,
      'accountId': accountId,
      'accessToken': accessToken,
    });
  }

  Future<void> clearSession() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('clearSession');
  }

  Future<void> shareInvite(String inviteUrl, String contactName) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('shareInvite', {
      'url': inviteUrl,
      'contactName': contactName,
    });
  }

  Future<void> openUrl(String url) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('openUrl', {'url': url});
  }

  Future<String?> _read(String method) async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    return _channel.invokeMethod<String>(method);
  }
}

/// Demo API for the routes in contracts/openapi.yaml.
///
/// The emulator uses 10.0.2.2 to reach the host machine. For a physical phone,
/// use `--dart-define=API_BASE_URL=http://laptop-LAN-IP:8000`.
class DemoApi {
  const DemoApi({this.identity = const DeviceIdentity(), this._baseUri});

  static const _configuredBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  );
  static const _configuredRelayUrl = String.fromEnvironment('RELAY_BASE_URL');

  final DeviceIdentity identity;
  final Uri? _baseUri;

  Uri get baseUri => _baseUri ?? Uri.parse(_configuredBaseUrl);

  Uri get relayUri {
    if (_configuredRelayUrl.isNotEmpty) return Uri.parse(_configuredRelayUrl);
    return baseUri.replace(
      scheme: baseUri.scheme == 'https' ? 'wss' : 'ws',
      path: '/relay/ws',
      query: null,
      fragment: null,
    );
  }

  Future<void> requestOtp(String email) async {
    await _request(
      'POST',
      '/auth/otp/request',
      body: {'email': email},
      authenticated: false,
    );
  }

  Future<void> verifyOtp({required String email, required String code}) async {
    final session = await _request(
      'POST',
      '/auth/otp/verify',
      body: {
        'email': email,
        'code': code,
        'device_public_key': await identity.publicKey(),
      },
      authenticated: false,
    );
    await _saveSession(session);
  }

  /// Returns false when this install has never completed email verification.
  Future<bool> trySilentSignIn() async {
    String? deviceId;
    try {
      deviceId = await identity.deviceId();
    } catch (_) {
      return false;
    }
    if (deviceId == null || deviceId.isEmpty) return false;
    try {
      await _signInWithDevice(deviceId);
      return true;
    } on ApiException catch (error) {
      if (error.statusCode == 401) await identity.clearSession();
      return false;
    } on SocketException {
      // An offline launch can still use the phone's local safety features.
      return false;
    } on HttpException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _signInWithDevice(String deviceId) async {
    final challenge = await _request(
      'POST',
      '/auth/device/challenge',
      body: {'device_id': deviceId},
      authenticated: false,
    );
    final signature = await identity.signChallenge(
      deviceId,
      challenge['nonce'] as String,
    );
    final session = await _request(
      'POST',
      '/auth/device/verify',
      body: {
        'device_id': deviceId,
        'nonce': challenge['nonce'],
        'signature': signature,
      },
      authenticated: false,
    );
    await _saveSession(session);
  }

  Future<Map<String, dynamic>> createInvite(String ownerLabel) =>
      _request('POST', '/contacts/invites', body: {'owner_label': ownerLabel});

  /// Accepts a trusted-contact invite. Takes the full invite link or just the
  /// token, and returns the inviter's label.
  Future<String> acceptInvite(String linkOrToken) async {
    final token = inviteTokenFrom(linkOrToken);
    if (token.isEmpty) throw const ApiException(400, 'invite_invalid');
    final result = await _request(
      'POST',
      '/contacts/invites/accept',
      body: {'invite_token': token},
    );
    return result['owner_label'] as String? ?? 'SixthSense user';
  }

  /// The token is everything after `#` in the invite link (never sent to web
  /// servers by browsers). A bare token is returned as is.
  static String inviteTokenFrom(String linkOrToken) {
    final trimmed = linkOrToken.trim();
    final hash = trimmed.lastIndexOf('#');
    return (hash >= 0 ? trimmed.substring(hash + 1) : trimmed).trim();
  }

  /// Open alerts where this account is a trusted contact (GET /escalations/active).
  Future<List<ContactAlert>> activeAlerts() async {
    final result = await _request('GET', '/escalations/active');
    return (result['escalations'] as List<dynamic>? ?? const [])
        .map((item) => ContactAlert.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// "I'm on it": stops further alerts to everyone.
  Future<void> acknowledgeAlert(String id) =>
      _request('POST', '/escalations/$id/ack');

  /// Contact confirmed the person is OK.
  Future<void> resolveAlert(String id) =>
      _request('POST', '/escalations/$id/resolve');

  /// "I can't reach them": turns a missed check-in into a full alert.
  Future<void> raiseAlarm(String id) =>
      _request('POST', '/escalations/$id/raise');

  Future<String> createTelegramLink() async {
    final result = await _request('POST', '/notifications/telegram/link');
    return result['url'] as String;
  }

  Future<JourneySnapshot> startJourney(int checkInIntervalMinutes) async =>
      JourneySnapshot.fromJson(
        await _request(
          'POST',
          '/journeys',
          body: {'check_in_interval_min': checkInIntervalMinutes},
        ),
      );

  Future<JourneySnapshot> heartbeat(String journeyId) async =>
      JourneySnapshot.fromJson(
        await _request('POST', '/journeys/$journeyId/heartbeat'),
      );

  Future<JourneySnapshot> promptShown(String journeyId) async =>
      JourneySnapshot.fromJson(
        await _request('POST', '/journeys/$journeyId/prompt'),
      );

  Future<JourneySnapshot> checkIn(
    String journeyId, {
    required bool duress,
  }) async => JourneySnapshot.fromJson(
    await _request(
      'POST',
      '/journeys/$journeyId/check-in',
      body: {'result': duress ? 'duress' : 'ok'},
    ),
  );

  Future<JourneySnapshot> requestSos(
    String journeyId, {
    required bool covert,
  }) async => JourneySnapshot.fromJson(
    await _request(
      'POST',
      '/journeys/$journeyId/sos',
      body: {'covert': covert},
    ),
  );

  Future<JourneySnapshot> endJourney(String journeyId) async =>
      JourneySnapshot.fromJson(
        await _request('POST', '/journeys/$journeyId/end'),
      );

  Future<void> _saveSession(Map<String, dynamic> json) async {
    await identity.saveSession(
      deviceId: json['device_id'] as String,
      accountId: json['account_id'] as String,
      accessToken: json['access_token'] as String,
    );
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, Object?>? body,
    bool authenticated = true,
    bool retryUnauthorized = true,
  }) async {
    var token = authenticated ? await identity.accessToken() : null;
    if (authenticated && (token == null || token.isEmpty)) {
      final deviceId = await identity.deviceId();
      if (deviceId == null || deviceId.isEmpty) {
        throw const ApiException(401, 'not_authenticated');
      }
      await _signInWithDevice(deviceId);
      token = await identity.accessToken();
    }

    final uri = baseUri.resolve(path);
    debugPrint('DemoApi $method ${uri.origin}${uri.path}');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 15));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      if (token != null && token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      debugPrint('DemoApi $method $path -> HTTP ${response.statusCode}');
      final responseBody = await utf8.decoder.bind(response).join();
      if (response.statusCode == 401 && authenticated && retryUnauthorized) {
        final deviceId = await identity.deviceId();
        if (deviceId != null && deviceId.isNotEmpty) {
          await _signInWithDevice(deviceId);
          return await _request(
            method,
            path,
            body: body,
            authenticated: authenticated,
            retryUnauthorized: false,
          );
        }
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        var detail = 'request_failed';
        try {
          detail =
              (jsonDecode(responseBody) as Map)['detail'] as String? ?? detail;
        } on FormatException {
          // Keep the HTTP status as the actionable error for non-JSON responses.
        }
        throw ApiException(response.statusCode, detail);
      }
      if (responseBody.isEmpty) return <String, dynamic>{};
      return jsonDecode(responseBody) as Map<String, dynamic>;
    } on SocketException catch (error) {
      throw ApiException(0, 'server_unreachable', cause: error);
    } on TimeoutException catch (error) {
      throw ApiException(0, 'server_timeout', cause: error);
    } finally {
      client.close(force: true);
    }
  }
}

class ApiException implements Exception {
  const ApiException(this.statusCode, this.detail, {this.cause});

  final int statusCode;
  final String detail;
  final Object? cause;

  @override
  String toString() => 'API request failed ($statusCode): $detail';
}

class JourneySnapshot {
  const JourneySnapshot({
    required this.id,
    required this.state,
    required this.nextCheckInAt,
    required this.heartbeatTimeoutMinutes,
  });

  final String id;
  final String state;
  final DateTime nextCheckInAt;
  final int heartbeatTimeoutMinutes;

  factory JourneySnapshot.fromJson(Map<String, dynamic> json) =>
      JourneySnapshot(
        id: json['id'] as String,
        state: json['state'] as String,
        nextCheckInAt: DateTime.parse(json['next_check_in_at'] as String)
            .toLocal(),
        heartbeatTimeoutMinutes:
            (json['timers'] as Map<String, dynamic>)['heartbeat_timeout_min']
                as int,
      );
}

class ContactAlert {
  const ContactAlert({
    required this.id,
    required this.ownerLabel,
    required this.fullEscalation,
    required this.covert,
    required this.openedAt,
    required this.acknowledged,
    required this.verificationCode,
  });

  final String id;
  final String ownerLabel;

  /// false = missed check-in (contacts asked first); true = full alert (SOS).
  final bool fullEscalation;

  /// Silent alarm: never call their phone.
  final bool covert;
  final DateTime openedAt;
  final bool acknowledged;

  /// Same code as in the Telegram message; if they differ, the message is fake.
  final String verificationCode;

  factory ContactAlert.fromJson(Map<String, dynamic> json) => ContactAlert(
    id: json['id'] as String,
    ownerLabel: json['owner_label'] as String,
    fullEscalation: json['level'] == 'full_escalation',
    covert: json['covert'] as bool? ?? false,
    openedAt: DateTime.parse(json['opened_at'] as String).toLocal(),
    acknowledged: json['acknowledged'] as bool? ?? false,
    verificationCode: json['verification_code'] as String,
  );
}
