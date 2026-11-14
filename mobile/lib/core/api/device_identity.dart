import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'walk_models.dart';

export 'walk_models.dart';

class VerificationImage {
  const VerificationImage({required this.bytes, required this.mimeType});

  final Uint8List bytes;
  final String mimeType;
}

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

  /// Small values kept only on this phone, encrypted with a Keystore key.
  Future<void> saveValue(String name, String? value) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('saveValue', {
      'name': name,
      'value': value,
    });
  }

  Future<String?> readValue(String name) async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    return _channel.invokeMethod<String>('readValue', {'name': name});
  }

  Future<void> clearSession() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('clearSession');
  }

  /// Logout: forget the session and saved values, and retire the device key.
  Future<void> signOut() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('signOut');
  }

  /// Send the app to the background (Back on the home screen) instead of closing it.
  Future<void> moveToBack() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('moveToBack');
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

  Future<Map<String, dynamic>> createVerificationSession({
    required bool consent,
    bool faceTemplateConsent = false,
  }) => _request(
    'POST',
    '/verification/sessions',
    body: {
      'purpose': 'responder',
      'consent': consent,
      'face_template_consent': faceTemplateConsent,
    },
  );

  Future<Map<String, dynamic>> submitVerificationSelfie({
    required String sessionId,
    required String idType,
    required String idNumber,
    required String dateOfBirth,
    required VerificationImage idImage,
    required VerificationImage selfieImage,
    String? scenario,
  }) {
    final fields = <String, String>{
      'id_type': idType,
      'id_number': idNumber,
      'date_of_birth': dateOfBirth,
    };
    if (scenario case final value?) fields['scenario'] = value;
    return _requestMultipart(
      '/verification/sessions/$sessionId/selfie',
      fields: fields,
      images: {'id_image': idImage, 'selfie_image': selfieImage},
    );
  }

  Future<Map<String, dynamic>> verificationSession(String sessionId) =>
      _request('GET', '/verification/sessions/$sessionId');

  Future<Map<String, dynamic>> verificationMe() =>
      _request('GET', '/verification/me');

  Future<void> deleteFaceTemplate() =>
      _request('DELETE', '/verification/face-template');

  Future<void> enrollFaceTemplate({
    required VerificationImage idImage,
    required VerificationImage selfieImage,
  }) => _requestMultipart(
    '/verification/face-template',
    fields: const {'consent': 'true'},
    images: {'id_image': idImage, 'selfie_image': selfieImage},
  );

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

  /// A valid access token for the relay socket (signs in again with the device key if needed).
  Future<String> freshAccessToken({bool renew = false}) async {
    var token = renew ? null : await identity.accessToken();
    if (token == null || token.isEmpty) {
      final deviceId = await identity.deviceId();
      if (deviceId == null || deviceId.isEmpty) {
        throw const ApiException(401, 'not_authenticated');
      }
      await _signInWithDevice(deviceId);
      token = await identity.accessToken();
    }
    if (token == null || token.isEmpty) {
      throw const ApiException(401, 'not_authenticated');
    }
    return token;
  }

  /// Publishes this device's E2E public keys (base64 raw 32 bytes); returns the key id.
  Future<String> uploadE2EKeys({
    required String x25519PublicKey,
    required String ed25519PublicKey,
  }) async {
    final result = await _request(
      'PUT',
      '/auth/device/e2e-keys',
      body: {
        'x25519_public_key': x25519PublicKey,
        'ed25519_public_key': ed25519PublicKey,
      },
    );
    return result['key_id'] as String;
  }

  /// My trusted contacts as the server knows them (ids and status only, no names).
  Future<List<Map<String, dynamic>>> listContacts() async {
    final result = await _request('GET', '/contacts');
    return (result['contacts'] as List).cast<Map<String, dynamic>>();
  }

  Future<void> removeContact(String linkId) =>
      _request('DELETE', '/contacts/$linkId');

  /// E2E public keys of an accepted contact's devices.
  Future<List<Map<String, dynamic>>> contactKeys(String linkId) async {
    final result = await _request('GET', '/contacts/$linkId/keys');
    return (result['keys'] as List).cast<Map<String, dynamic>>();
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

  /// For a contact who said "I'm on it": the traveller's keys, to share my
  /// location back so they see me coming.
  Future<OwnerKeys> alertOwnerKeys(String escalationId) async =>
      OwnerKeys.fromJson(
        await _request('GET', '/escalations/$escalationId/owner-keys'),
      );

  /// The traveller's view during a journey: is an alert open, who is coming.
  Future<HelpView> help(String journeyId) async =>
      HelpView.fromJson(await _request('GET', '/escalations/help/$journeyId'));

  /// Rough area during a full alert, so nearby responders can be asked.
  Future<void> sendAlertArea(String journeyId, double lat, double lng) =>
      _request(
        'PUT',
        '/escalations/area/$journeyId',
        body: {'latitude': lat, 'longitude': lng},
      );

  // ---- Responders (F6) ----

  Future<ResponderMe> responderMe() async =>
      ResponderMe.fromJson(await _request('GET', '/responders/me'));

  Future<ResponderMe> applyAsResponder(String displayName) async =>
      ResponderMe.fromJson(
        await _request(
          'POST',
          '/responders/apply',
          body: {'display_name': displayName},
        ),
      );

  Future<void> sendPresence(double lat, double lng) => _request(
    'PUT',
    '/responders/presence',
    body: {'latitude': lat, 'longitude': lng},
  );

  Future<void> goOffDuty() => _request('DELETE', '/responders/presence');

  Future<List<ResponderOffer>> responderOffers() async {
    final result = await _request('GET', '/responders/offers');
    return (result['offers'] as List<dynamic>? ?? const [])
        .map((item) => ResponderOffer.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// "I'm going": returns the traveller's keys for sharing my location back.
  /// Saying it needs a fresh face [scan]; once going, asking again (no scan)
  /// returns the keys.
  Future<OwnerKeys> goingToHelp(
    String offerId, {
    VerificationImage? scan,
  }) async => OwnerKeys.fromJson(
    scan == null
        ? await _request('POST', '/responders/offers/$offerId/going')
        : await _requestMultipart(
            '/responders/offers/$offerId/going',
            fields: const {},
            images: {'selfie_image': scan},
          ),
  );

  Future<void> declineOffer(String offerId) =>
      _request('POST', '/responders/offers/$offerId/decline');

  Future<void> arrivedAtOffer(String offerId) =>
      _request('POST', '/responders/offers/$offerId/arrived');

  Future<String> createTelegramLink() async {
    final result = await _request('POST', '/notifications/telegram/link');
    return result['url'] as String;
  }

  /// Starts a journey. The app only calls this when it has no journey running,
  /// so an open one on the server is left over (for example the phone timer
  /// failed to start after the server journey was created): end it and retry.
  Future<JourneySnapshot> startJourney(int checkInIntervalMinutes) async {
    Future<Map<String, dynamic>> create() => _request(
      'POST',
      '/journeys',
      body: {'check_in_interval_min': checkInIntervalMinutes},
    );
    try {
      return JourneySnapshot.fromJson(await create());
    } on ApiException catch (error) {
      if (error.detail != 'journey_already_open') rethrow;
      final current = await _request('GET', '/journeys/current');
      await endJourney(current['id'] as String);
      return JourneySnapshot.fromJson(await create());
    }
  }

  /// The journey still open on the server for this account, or null (404).
  Future<JourneySnapshot?> currentJourney() async {
    try {
      return JourneySnapshot.fromJson(
        await _request('GET', '/journeys/current'),
      );
    } on ApiException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Signs this phone out on the server (token ended, device key retired).
  Future<void> logout() async {
    await _request('POST', '/auth/logout', retryUnauthorized: false);
  }

  /// Responders who said "I'm going" on this journey's alert, not rated yet.
  Future<List<ResponderToRate>> respondersToRate(String journeyId) async {
    final json = await _request('GET', '/feedback/responders/$journeyId');
    return (json['responders'] as List<dynamic>? ?? const [])
        .map((item) => ResponderToRate.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<void> rateResponder({
    required String offerId,
    required int stars,
    String note = '',
  }) async {
    await _request(
      'POST',
      '/feedback/responder',
      body: {'offer_id': offerId, 'stars': stars, 'note': note},
    );
  }

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

  // ---- Audio Escort (P1-W3) ----

  Future<Escort> startEscort({
    required String journeyId,
    required int minutes,
    required List<String> contactLinkIds,
    String? requestId,
  }) async => Escort.fromJson(
    await _request(
      'POST',
      '/escorts',
      body: {
        'journey_id': journeyId,
        'minutes': minutes,
        'contact_link_ids': contactLinkIds,
        'request_id': ?requestId,
      },
    ),
  );

  /// My running escort, or null.
  Future<Escort?> currentEscort() async {
    try {
      return Escort.fromJson(await _request('GET', '/escorts/current'));
    } on ApiException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  /// [duress] gets the same answer but also raises a silent alarm.
  Future<void> stopEscort(String escortId, {required bool duress}) => _request(
    'POST',
    '/escorts/$escortId/stop',
    body: {'result': duress ? 'duress' : 'ok'},
  );

  /// Escorts I can listen to right now.
  Future<List<ListeningEscort>> listeningEscorts() async {
    final result = await _request('GET', '/escorts/listening');
    return [
      for (final item in result['escorts'] as List)
        ListeningEscort.fromJson(item as Map<String, dynamic>),
    ];
  }

  /// People who made me their trusted contact.
  Future<List<SupportedPerson>> supporting() async {
    final result = await _request('GET', '/escorts/supporting');
    return [
      for (final item in result['people'] as List)
        SupportedPerson.fromJson(item as Map<String, dynamic>),
    ];
  }

  Future<void> askForEscort(String contactLinkId) => _request(
    'POST',
    '/escorts/requests',
    body: {'contact_link_id': contactLinkId},
  );

  Future<List<EscortRequestView>> escortRequests() async {
    final result = await _request('GET', '/escorts/requests');
    return [
      for (final item in result['requests'] as List)
        EscortRequestView.fromJson(item as Map<String, dynamic>),
    ];
  }

  Future<void> declineEscortRequest(String requestId) =>
      _request('POST', '/escorts/requests/$requestId/decline');

  // ---- Profile (P1-W3) ----

  /// My profile, or null right after the first sign-in (404 no_profile).
  Future<Profile?> profile() async {
    try {
      return Profile.fromJson(await _request('GET', '/profile'));
    } on ApiException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<Profile> saveProfile(Profile profile) async => Profile.fromJson(
    await _request('PUT', '/profile', body: profile.toJson()),
  );

  // ---- Walk With Me (P3-W3) ----

  Future<CompanionMe> companionMe() async =>
      CompanionMe.fromJson(await _request('GET', '/walks/companion/me'));

  /// Become a companion. Needs a verified identity (409 identity_not_verified:
  /// open identity verification first). No approval step.
  Future<CompanionMe> joinAsCompanion() async =>
      CompanionMe.fromJson(await _request('POST', '/walks/companion/join'));

  Future<void> sendCompanionPresence(double lat, double lng) => _request(
    'PUT',
    '/walks/companion/presence',
    body: {'latitude': lat, 'longitude': lng},
  );

  Future<void> goUnavailable() =>
      _request('DELETE', '/walks/companion/presence');

  Future<List<CompanionCard>> searchCompanions({
    required String journeyId,
    required double lat,
    required double lng,
    bool womenOnly = false,
  }) async {
    final result = await _request(
      'POST',
      '/walks/search',
      body: {
        'journey_id': journeyId,
        'latitude': lat,
        'longitude': lng,
        'women_only': womenOnly,
      },
    );
    return (result['companions'] as List<dynamic>? ?? const [])
        .map((item) => CompanionCard.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<WalkView> askCompanion({
    required String journeyId,
    required String companionId,
    required double lat,
    required double lng,
  }) async => WalkView.fromJson(
    await _request(
      'POST',
      '/walks',
      body: {
        'journey_id': journeyId,
        'companion_id': companionId,
        'latitude': lat,
        'longitude': lng,
      },
    ),
  );

  Future<List<WalkRequestView>> walkRequests() async {
    final result = await _request('GET', '/walks/requests');
    return (result['requests'] as List<dynamic>? ?? const [])
        .map((item) => WalkRequestView.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// My open walk (requested or accepted), or null.
  Future<WalkView?> currentWalk() async {
    try {
      return WalkView.fromJson(await _request('GET', '/walks/current'));
    } on ApiException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<WalkView> walk(String walkId) async =>
      WalkView.fromJson(await _request('GET', '/walks/$walkId'));

  /// Accept with a fresh face [scan], checked by the server in this request.
  Future<WalkView> acceptWalk(
    String walkId, {
    required VerificationImage scan,
  }) async => WalkView.fromJson(
    await _requestMultipart(
      '/walks/$walkId/accept',
      fields: const {},
      images: {'selfie_image': scan},
    ),
  );

  Future<void> declineWalk(String walkId) =>
      _request('POST', '/walks/$walkId/decline');

  Future<void> cancelWalk(String walkId) =>
      _request('POST', '/walks/$walkId/cancel');

  Future<WalkView> endWalk(String walkId) async =>
      WalkView.fromJson(await _request('POST', '/walks/$walkId/end'));

  // ---- How was it? (P1-W3) ----

  Future<void> sendFeedback(FeedbackDraft draft) =>
      _request('POST', '/feedback', body: draft.toJson());

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
      // All headers must be set before the body is written; Dart locks them after.
      if (token != null && token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
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
      if (responseBody.trim().isEmpty) return <String, dynamic>{}; // 204
      return jsonDecode(responseBody) as Map<String, dynamic>;
    } on SocketException catch (error) {
      throw ApiException(0, 'server_unreachable', cause: error);
    } on TimeoutException catch (error) {
      throw ApiException(0, 'server_timeout', cause: error);
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _requestMultipart(
    String path, {
    required Map<String, String> fields,
    required Map<String, VerificationImage> images,
    bool retryUnauthorized = true,
  }) async {
    var token = await identity.accessToken();
    if (token == null || token.isEmpty) {
      final deviceId = await identity.deviceId();
      if (deviceId == null || deviceId.isEmpty) {
        throw const ApiException(401, 'not_authenticated');
      }
      await _signInWithDevice(deviceId);
      token = await identity.accessToken();
    }
    final uri = baseUri.resolve(path);
    final boundary = 'sixthsense-${DateTime.now().microsecondsSinceEpoch}';
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client
          .postUrl(uri)
          .timeout(const Duration(seconds: 15));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'multipart/form-data; boundary=$boundary',
      );
      if (token != null && token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      for (final entry in fields.entries) {
        request.write('--$boundary\r\n');
        request.write(
          'Content-Disposition: form-data; name="${entry.key}"\r\n\r\n',
        );
        request.write(entry.value);
        request.write('\r\n');
      }
      for (final entry in images.entries) {
        request.write('--$boundary\r\n');
        request.write(
          'Content-Disposition: form-data; name="${entry.key}"; '
          'filename="${entry.key}.jpg"\r\n',
        );
        request.write('Content-Type: ${entry.value.mimeType}\r\n\r\n');
        request.add(entry.value.bytes);
        request.write('\r\n');
      }
      request.write('--$boundary--\r\n');
      final response = await request.close().timeout(
        const Duration(seconds: 35),
      );
      final responseBody = await utf8.decoder.bind(response).join();
      if (response.statusCode == 401 && retryUnauthorized) {
        final deviceId = await identity.deviceId();
        if (deviceId != null && deviceId.isNotEmpty) {
          await _signInWithDevice(deviceId);
          return await _requestMultipart(
            path,
            fields: fields,
            images: images,
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
          // Preserve only a short status code for non-JSON responses.
        }
        throw ApiException(response.statusCode, detail);
      }
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

class ResponderToRate {
  const ResponderToRate({required this.offerId, required this.name});

  final String offerId;
  final String name;

  factory ResponderToRate.fromJson(Map<String, dynamic> json) => ResponderToRate(
    offerId: json['offer_id'] as String,
    name: json['name'] as String? ?? 'Responder',
  );
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
    this.journeyId,
    this.iAmHelping = false,
    this.helpersGoing = 0,
  });

  /// I said "I'm on it", so I share my location back to them.
  final bool iAmHelping;
  final int helpersGoing;

  final String id;
  final String ownerLabel;

  /// The traveller's journey; live location envelopes carry it as session id.
  final String? journeyId;

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
    journeyId: json['journey_id'] as String?,
    fullEscalation: json['level'] == 'full_escalation',
    covert: json['covert'] as bool? ?? false,
    openedAt: DateTime.parse(json['opened_at'] as String).toLocal(),
    acknowledged: json['acknowledged'] as bool? ?? false,
    verificationCode: json['verification_code'] as String,
    iAmHelping: json['i_am_helping'] as bool? ?? false,
    helpersGoing: json['helpers_going'] as int? ?? 0,
  );
}

/// A device public key of another person (for E2E live location).
class PeerKey {
  const PeerKey({
    required this.keyId,
    required this.x25519PublicKey,
    required this.ed25519PublicKey,
  });

  final String keyId;
  final String x25519PublicKey;
  final String ed25519PublicKey;

  factory PeerKey.fromJson(Map<String, dynamic> json) => PeerKey(
    keyId: json['key_id'] as String,
    x25519PublicKey: json['x25519_public_key'] as String,
    ed25519PublicKey: json['ed25519_public_key'] as String,
  );

  static List<PeerKey> listFrom(Object? raw) => (raw as List<dynamic>? ?? [])
      .map((item) => PeerKey.fromJson(item as Map<String, dynamic>))
      .toList();
}

class OwnerKeys {
  const OwnerKeys({required this.journeyId, required this.keys});

  final String journeyId;
  final List<PeerKey> keys;

  factory OwnerKeys.fromJson(Map<String, dynamic> json) => OwnerKeys(
    journeyId: json['journey_id'] as String,
    keys: PeerKey.listFrom(json['keys']),
  );
}

/// Someone coming to help me (a contact or a verified responder).
class Helper {
  const Helper({
    required this.id,
    required this.isResponder,
    required this.label,
    required this.contactLinkId,
    required this.arrived,
    required this.acceptedAt,
    required this.keys,
  });

  final String id;
  final bool isResponder;

  /// Responder's display name; contacts are named from the phone's contact book.
  final String? label;
  final String? contactLinkId;
  final bool arrived;
  final DateTime acceptedAt;
  final List<PeerKey> keys;

  factory Helper.fromJson(Map<String, dynamic> json) => Helper(
    id: json['id'] as String,
    isResponder: json['kind'] == 'responder',
    label: json['label'] as String?,
    contactLinkId: json['contact_link_id'] as String?,
    arrived: json['status'] == 'arrived',
    acceptedAt: DateTime.parse(json['accepted_at'] as String).toLocal(),
    keys: PeerKey.listFrom(json['keys']),
  );
}

/// Nearby responder search during a full alert: counts only, never who/where.
class ResponderSearch {
  const ResponderSearch({
    required this.radiusMeters,
    required this.onDutyNearby,
    required this.asked,
    required this.going,
  });

  final int radiusMeters;
  final int onDutyNearby;
  final int asked;
  final int going;

  factory ResponderSearch.fromJson(Map<String, dynamic> json) =>
      ResponderSearch(
        radiusMeters: json['radius_m'] as int,
        onDutyNearby: json['on_duty_nearby'] as int,
        asked: json['asked'] as int,
        going: json['going'] as int,
      );
}

class HelpView {
  const HelpView({
    required this.fullAlert,
    required this.anyAlert,
    required this.helpers,
    this.search,
  });

  final ResponderSearch? search;

  static const none = HelpView(fullAlert: false, anyAlert: false, helpers: []);

  final bool fullAlert;
  final bool anyAlert;
  final List<Helper> helpers;

  factory HelpView.fromJson(Map<String, dynamic> json) => HelpView(
    fullAlert: json['full_alert'] as bool? ?? false,
    anyAlert: json['any_alert'] as bool? ?? false,
    helpers: (json['helpers'] as List<dynamic>? ?? const [])
        .map((item) => Helper.fromJson(item as Map<String, dynamic>))
        .toList(),
    search: json['search'] == null
        ? null
        : ResponderSearch.fromJson(json['search'] as Map<String, dynamic>),
  );
}

class ResponderMe {
  const ResponderMe({
    required this.status,
    this.displayName,
    this.onDuty = false,
  });

  /// none | approved (applied; no approval step) | revoked
  final String status;
  final String? displayName;
  final bool onDuty;

  bool get approved => status == 'approved';

  factory ResponderMe.fromJson(Map<String, dynamic> json) => ResponderMe(
    status: json['status'] as String? ?? 'none',
    displayName: json['display_name'] as String?,
    onDuty: json['on_duty'] as bool? ?? false,
  );
}

/// Someone nearby asked for help and I am an on-duty responder.
class ResponderOffer {
  const ResponderOffer({
    required this.id,
    required this.status,
    required this.distanceMeters,
    required this.walkMinutes,
    required this.covert,
    required this.openedAt,
    required this.helpersGoing,
    required this.arrived,
    this.journeyId,
    this.roughLatitude,
    this.roughLongitude,
  });

  final String id;

  /// offered | going
  final String status;
  final int distanceMeters;
  final int walkMinutes;
  final bool covert;
  final DateTime openedAt;
  final int helpersGoing;
  final bool arrived;

  /// Set once I said "I'm going"; matches the live location session id.
  final String? journeyId;
  final double? roughLatitude;
  final double? roughLongitude;

  bool get going => status == 'going';

  factory ResponderOffer.fromJson(Map<String, dynamic> json) {
    final area = json['rough_area'] as Map<String, dynamic>?;
    return ResponderOffer(
      id: json['id'] as String,
      status: json['status'] as String,
      distanceMeters: json['distance_m'] as int,
      walkMinutes: json['walk_minutes'] as int,
      covert: json['covert'] as bool? ?? false,
      openedAt: DateTime.parse(json['opened_at'] as String).toLocal(),
      helpersGoing: json['helpers_going'] as int? ?? 0,
      arrived: json['arrived'] as bool? ?? false,
      journeyId: json['journey_id'] as String?,
      roughLatitude: (area?['latitude'] as num?)?.toDouble(),
      roughLongitude: (area?['longitude'] as num?)?.toDouble(),
    );
  }
}

class Escort {
  const Escort({
    required this.id,
    required this.journeyId,
    required this.endsAt,
    required this.listenerLinkIds,
  });

  factory Escort.fromJson(Map<String, dynamic> json) => Escort(
    id: json['id'] as String,
    journeyId: json['journey_id'] as String,
    endsAt: DateTime.parse(json['ends_at'] as String).toLocal(),
    listenerLinkIds: [
      for (final id in json['listener_link_ids'] as List) id as String,
    ],
  );

  final String id;
  final String journeyId;
  final DateTime endsAt;
  final List<String> listenerLinkIds;
}

class ListeningEscort {
  const ListeningEscort({
    required this.escortId,
    required this.journeyId,
    required this.ownerLabel,
    required this.endsAt,
  });

  factory ListeningEscort.fromJson(Map<String, dynamic> json) =>
      ListeningEscort(
        escortId: json['escort_id'] as String,
        journeyId: json['journey_id'] as String,
        ownerLabel: json['owner_label'] as String,
        endsAt: DateTime.parse(json['ends_at'] as String).toLocal(),
      );

  final String escortId;
  final String journeyId;
  final String ownerLabel;
  final DateTime endsAt;
}

class SupportedPerson {
  const SupportedPerson({
    required this.contactLinkId,
    required this.ownerLabel,
  });

  factory SupportedPerson.fromJson(Map<String, dynamic> json) =>
      SupportedPerson(
        contactLinkId: json['contact_link_id'] as String,
        ownerLabel: json['owner_label'] as String,
      );

  final String contactLinkId;
  final String ownerLabel;
}

class EscortRequestView {
  const EscortRequestView({required this.id, required this.contactLinkId});

  factory EscortRequestView.fromJson(Map<String, dynamic> json) =>
      EscortRequestView(
        id: json['id'] as String,
        contactLinkId: json['contact_link_id'] as String,
      );

  final String id;
  final String contactLinkId;
}
