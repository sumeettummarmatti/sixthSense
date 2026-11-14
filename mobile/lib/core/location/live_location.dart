import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../api/device_identity.dart';
import '../crypto/live_location_cipher.dart';

/// Live location to trusted contacts during a journey (F4).
///
/// The traveller's phone encrypts each GPS fix separately for every device of
/// every accepted contact (X25519 + AES-GCM, signed with Ed25519). The server
/// only forwards ciphertext over the relay socket and stores nothing (rule 2).
/// Contacts only receive while the traveller's journey is open (rule 4,
/// enforced by the server).

/// This device's E2E key pairs. Seeds stay on the phone (Keystore-encrypted);
/// public keys are published once per device sign-in.
class E2EKeyring {
  E2EKeyring._(this.keyId, this.agreement, this.signing);

  final String keyId;
  final SimpleKeyPair agreement;
  final SimpleKeyPair signing;

  static E2EKeyring? _cached;
  static Future<E2EKeyring>? _loading;

  static Future<E2EKeyring> load(DemoApi api) {
    final cached = _cached;
    if (cached != null) return Future.value(cached);
    return _loading ??= _load(api).whenComplete(() => _loading = null);
  }

  static Future<E2EKeyring> _load(DemoApi api) async {
    final identity = api.identity;
    var seeds = await identity.readValue('e2e_seeds');
    if (seeds == null) {
      final random = Random.secure();
      List<int> seed() => List<int>.generate(32, (_) => random.nextInt(256));
      seeds = jsonEncode({
        'x25519': base64Encode(seed()),
        'ed25519': base64Encode(seed()),
      });
      await identity.saveValue('e2e_seeds', seeds);
    }
    final decoded = jsonDecode(seeds) as Map<String, dynamic>;
    final agreement = await X25519().newKeyPairFromSeed(
      base64Decode(decoded['x25519'] as String),
    );
    final signing = await Ed25519().newKeyPairFromSeed(
      base64Decode(decoded['ed25519'] as String),
    );

    // Keys belong to a device sign-in; publish again after a new sign-in.
    final deviceId = await identity.deviceId() ?? '';
    final saved = await identity.readValue('e2e_key_id');
    String keyId;
    if (saved != null && saved.startsWith('$deviceId|')) {
      keyId = saved.substring(deviceId.length + 1);
    } else {
      keyId = await api.uploadE2EKeys(
        x25519PublicKey: base64Encode(
          (await agreement.extractPublicKey()).bytes,
        ),
        ed25519PublicKey: base64Encode(
          (await signing.extractPublicKey()).bytes,
        ),
      );
      await identity.saveValue('e2e_key_id', '$deviceId|$keyId');
    }
    return _cached = E2EKeyring._(keyId, agreement, signing);
  }

  /// Forget the cached keyring (for example after signing in again).
  static void reset() => _cached = null;
}

/// A decrypted location from someone I support.
class ReceivedLocation {
  const ReceivedLocation({
    required this.sessionId,
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.takenAt,
    required this.sequence,
  });

  final String sessionId;
  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final DateTime takenAt;
  final int sequence;
}

/// A voice clip from someone I support (SOS recording or Audio Escort),
/// decrypted on this phone. It is played and then discarded.
class ReceivedAudio {
  const ReceivedAudio({
    required this.sessionId,
    required this.kind,
    required this.sequence,
    required this.bytes,
  });

  final String sessionId;
  final String kind;
  final int sequence;
  final List<int> bytes;
}

/// The single relay socket for this phone: sends my location (and audio
/// during an alert or escort) on my journey, and receives both from people I
/// support.
class LiveLocationRelay {
  LiveLocationRelay._();

  static final instance = LiveLocationRelay._();

  /// Latest location per journey (session id) of people I support.
  final received = ValueNotifier<Map<String, ReceivedLocation>>({});

  /// What my own sharing is doing, for the journey screen.
  final sharing = ValueNotifier<SharingStatus>(SharingStatus.off);

  /// Voice clips from people I support, as they arrive.
  final _audio = StreamController<ReceivedAudio>.broadcast();
  Stream<ReceivedAudio> get audio => _audio.stream;

  /// When the last clip arrived, per journey (session) of people I support.
  final liveAudio = ValueNotifier<Map<String, DateTime>>({});

  DemoApi? _api;
  WebSocket? _socket;
  Completer<void>? _ready;
  bool _connecting = false;
  Timer? _reconnect;
  Timer? _ping;
  final _cipher = LiveLocationCipher();

  /// Start listening for locations (call once after sign-in).
  Future<void> start(DemoApi api) async {
    _api = api;
    await _connect();
  }

  /// Logout: close the socket and stop reconnecting until [start] is called again.
  Future<void> stop() async {
    await stopSharing();
    _api = null;
    _reconnect?.cancel();
    _ping?.cancel();
    final socket = _socket;
    _socket = null;
    await socket?.close();
  }

  Future<void> _connect() async {
    final api = _api;
    if (api == null || _connecting || _socket != null) return;
    _connecting = true;
    try {
      await E2EKeyring.load(api);
      final socket = await WebSocket.connect(api.relayUri.toString())
          .timeout(const Duration(seconds: 10));
      _socket = socket;
      _ready = Completer<void>();
      socket.add(
        jsonEncode({
          'type': 'auth',
          'access_token': await api.freshAccessToken(),
        }),
      );
      socket.listen(
        _onFrame,
        onDone: () => _dropped(renew: socket.closeCode == 4401),
        onError: (_) => _dropped(),
        cancelOnError: true,
      );
      _ping?.cancel();
      _ping = Timer.periodic(
        const Duration(seconds: 25),
        (_) => _send({'type': 'ping'}),
      );
    } catch (error) {
      debugPrint('LiveLocationRelay connect failed: $error');
      _dropped();
    } finally {
      _connecting = false;
    }
  }

  void _dropped({bool renew = false}) {
    _socket = null;
    _ping?.cancel();
    if (!(_ready?.isCompleted ?? true)) _ready?.completeError('closed');
    _ready = null;
    _reconnect?.cancel();
    _reconnect = Timer(const Duration(seconds: 3), () async {
      if (renew) {
        try {
          await _api?.freshAccessToken(renew: true);
        } catch (_) {}
      }
      await _connect();
    });
  }

  void _send(Map<String, Object?> frame) {
    try {
      _socket?.add(jsonEncode(frame));
    } catch (_) {}
  }

  Future<void> _onFrame(dynamic data) async {
    if (data is! String) return;
    final frame = jsonDecode(data) as Map<String, dynamic>;
    switch (frame['type']) {
      case 'ready':
        if (!(_ready?.isCompleted ?? true)) _ready!.complete();
      case 'location':
        await _onLocation(frame);
      case 'audio':
        await _onAudio(frame);
      case 'sent':
        final delivered = frame['delivered'] as int? ?? 0;
        if (sharing.value.active) {
          sharing.value = sharing.value.copyWith(delivered: delivered);
        }
      case 'error':
        debugPrint('LiveLocationRelay error: ${frame['detail']}');
    }
  }

  Future<void> _onLocation(Map<String, dynamic> frame) async {
    final api = _api;
    if (api == null) return;
    try {
      final keyring = await E2EKeyring.load(api);
      final envelope = LiveLocationEnvelope.fromJson(
        (frame['envelope'] as Map).cast<String, dynamic>(),
      );
      final sender = (frame['sender'] as Map).cast<String, dynamic>();
      final senderKeyId = sender['key_id'] as String;
      // On my own journey's session, the sender is someone coming to help me.
      final fromHelper = envelope.sessionId == _journeyId;
      final store = fromHelper ? helperLocations : received;
      final storeKey = fromHelper ? senderKeyId : envelope.sessionId;
      final previous = store.value[storeKey];
      final point = await _cipher.decrypt(
        envelope: envelope,
        expectedSessionId: envelope.sessionId,
        expectedRecipientKeyId: keyring.keyId,
        recipientKeyPair: keyring.agreement,
        sender: LocationSenderVerificationKey(
          keyId: senderKeyId,
          signingPublicKey: SimplePublicKey(
            base64Decode(sender['ed25519_public_key'] as String),
            type: KeyPairType.ed25519,
          ),
        ),
        lastAcceptedSequence: previous?.sequence,
      );
      store.value = {
        ...store.value,
        storeKey: ReceivedLocation(
          sessionId: envelope.sessionId,
          latitude: point.latitude,
          longitude: point.longitude,
          accuracyMeters: point.accuracyMeters,
          takenAt: point.timestamp.toLocal(),
          sequence: point.sequence,
        ),
      };
    } catch (error) {
      debugPrint('LiveLocationRelay dropped a location: $error');
    }
  }

  Future<void> _onAudio(Map<String, dynamic> frame) async {
    final api = _api;
    if (api == null) return;
    try {
      final keyring = await E2EKeyring.load(api);
      final envelope = LiveLocationEnvelope.fromJson(
        (frame['envelope'] as Map).cast<String, dynamic>(),
      );
      final sender = (frame['sender'] as Map).cast<String, dynamic>();
      final clip = await _cipher.decryptAudio(
        envelope: envelope,
        expectedSessionId: envelope.sessionId,
        expectedRecipientKeyId: keyring.keyId,
        recipientKeyPair: keyring.agreement,
        sender: LocationSenderVerificationKey(
          keyId: sender['key_id'] as String,
          signingPublicKey: SimplePublicKey(
            base64Decode(sender['ed25519_public_key'] as String),
            type: KeyPairType.ed25519,
          ),
        ),
      );
      liveAudio.value = {
        ...liveAudio.value,
        envelope.sessionId: DateTime.now(),
      };
      _audio.add(
        ReceivedAudio(
          sessionId: envelope.sessionId,
          kind: clip.kind,
          sequence: clip.sequence,
          bytes: clip.audio,
        ),
      );
    } catch (error) {
      debugPrint('LiveLocationRelay dropped an audio clip: $error');
    }
  }

  /// Sends one recorded clip of my journey, end to end encrypted, to everyone
  /// who may hear it. The server only forwards it to people alerted or
  /// listening to my escort (rule 4). False if it could not be sent now.
  Future<bool> sendAudio(AudioClip clip) async {
    final api = _api;
    final journeyId = _journeyId;
    if (api == null || journeyId == null) return false;
    await _connect();
    if (_socket == null) return false;
    if (_contactRecipients.isEmpty) await _loadContactRecipients();
    final recipients = _journeyRecipients;
    if (recipients.isEmpty) return false;
    try {
      final keyring = await E2EKeyring.load(api);
      final envelopes = <Map<String, Object>>[];
      for (final recipient in recipients.take(10)) {
        final envelope = await _cipher.encryptAudio(
          sessionId: journeyId,
          senderKeyId: keyring.keyId,
          senderSigningKeyPair: keyring.signing,
          recipient: recipient,
          clip: clip,
        );
        envelopes.add(envelope.toJson());
      }
      _send({'type': 'audio', 'envelopes': envelopes});
      return true;
    } catch (error) {
      debugPrint('LiveLocationRelay could not send audio: $error');
      return false;
    }
  }

  // ---- Sharing my location ----
  //
  // Two kinds of session, both end-to-end encrypted:
  // - my journey: to my accepted contacts, plus responders who said "I'm going";
  // - helping someone: to that traveller only, while I'm on my way to them.

  /// My latest GPS fix while anything is shared (for distances on screen).
  final myPosition = ValueNotifier<Position?>(null);

  /// People coming to help me, keyed by their device key id.
  final helperLocations = ValueNotifier<Map<String, ReceivedLocation>>({});

  StreamSubscription<Position>? _positions;
  Timer? _refreshRecipients;
  List<LocationRecipientKeys> _contactRecipients = const [];
  List<LocationRecipientKeys> _helperRecipients = const [];
  final _helping = <String, List<LocationRecipientKeys>>{};
  String? _journeyId;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);

  /// The journey I'm sharing, if any.
  String? get journeyId => _journeyId;

  /// Share precise location with my accepted contacts until [stopSharing].
  Future<void> startSharing(DemoApi api, String journeyId) async {
    _api = api;
    _journeyId = journeyId;
    sharing.value = const SharingStatus(active: true);
    unawaited(_loadContactRecipients()); // audio needs them even without GPS
    if (!await _locationAllowed()) {
      sharing.value = const SharingStatus(error: 'location_denied');
      return;
    }
    await _connect();
    await _loadContactRecipients();
    _refreshRecipients?.cancel();
    _refreshRecipients = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _loadContactRecipients(),
    );
    await _ensurePositions();
  }

  /// Helpers on their way to me (from the journey's help view). Responders
  /// among them start receiving my precise location; contacts already do.
  void setJourneyHelpers(List<PeerKey> keys) {
    _helperRecipients = [for (final key in keys) _recipientKey(key)];
    _updateRecipientCount();
  }

  Future<void> stopSharing() async {
    _journeyId = null;
    _refreshRecipients?.cancel();
    _contactRecipients = const [];
    _helperRecipients = const [];
    helperLocations.value = {};
    sharing.value = SharingStatus.off;
    await _maybeStopPositions();
  }

  /// I'm going to help: share my location with that traveller only.
  Future<bool> startHelping(DemoApi api, OwnerKeys owner) async {
    _api = api;
    if (!await _locationAllowed()) return false;
    _helping[owner.journeyId] = [
      for (final key in owner.keys) _recipientKey(key),
    ];
    await _connect();
    await _ensurePositions();
    return true;
  }

  bool isHelping(String journeyId) => _helping.containsKey(journeyId);

  Future<void> stopHelping(String journeyId) async {
    if (_helping.remove(journeyId) == null) return;
    await _maybeStopPositions();
  }

  /// Stop helping everyone not in [stillOpen] (their alert closed).
  Future<void> keepHelpingOnly(Set<String> stillOpen) async {
    final ended = _helping.keys.where((id) => !stillOpen.contains(id)).toList();
    for (final id in ended) {
      _helping.remove(id);
    }
    if (ended.isNotEmpty) await _maybeStopPositions();
  }

  static LocationRecipientKeys _recipientKey(PeerKey key) =>
      LocationRecipientKeys(
        keyId: key.keyId,
        keyAgreementPublicKey: SimplePublicKey(
          base64Decode(key.x25519PublicKey),
          type: KeyPairType.x25519,
        ),
      );

  Future<void> _ensurePositions() async {
    if (_positions != null) return;
    _positions =
        Geolocator.getPositionStream(
          locationSettings: AndroidSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 0,
            intervalDuration: const Duration(seconds: 3),
            // Keeps GPS and sharing alive with the screen off or the phone in
            // a pocket (Android foreground service with a visible notice).
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'SixthSense is sharing your live location',
              notificationText:
                  'Only with your people or the person you are helping, '
                  'and only until the journey or alert ends.',
              enableWakeLock: true,
              setOngoing: true,
            ),
          ),
        ).listen(
          _onPosition,
          onError: (error) {
            sharing.value = sharing.value.copyWith(error: 'gps_unavailable');
          },
        );
  }

  Future<void> _maybeStopPositions() async {
    if (_journeyId != null || _helping.isNotEmpty) return;
    await _positions?.cancel();
    _positions = null;
    myPosition.value = null;
  }

  Future<bool> _locationAllowed() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  Future<void> _loadContactRecipients() async {
    final api = _api;
    if (api == null) return;
    try {
      final contacts = await api.listContacts();
      final keys = <LocationRecipientKeys>[];
      for (final contact in contacts) {
        if (contact['status'] != 'accepted') continue;
        for (final key in await api.contactKeys(contact['id'] as String)) {
          keys.add(_recipientKey(PeerKey.fromJson(key)));
        }
      }
      _contactRecipients = keys;
      _updateRecipientCount();
    } catch (error) {
      debugPrint('LiveLocationRelay could not load contact keys: $error');
    }
  }

  List<LocationRecipientKeys> get _journeyRecipients {
    final seen = <String>{};
    return [
      for (final key in [..._contactRecipients, ..._helperRecipients])
        if (seen.add(key.keyId)) key,
    ];
  }

  void _updateRecipientCount() {
    if (sharing.value.active) {
      sharing.value = sharing.value.copyWith(
        recipients: _journeyRecipients.length,
      );
    }
  }

  Future<void> _onPosition(Position position) async {
    myPosition.value = position;
    final api = _api;
    if (api == null) return;
    final now = DateTime.now();
    if (now.difference(_lastSent) < const Duration(seconds: 2)) return;
    _lastSent = now;
    if (_journeyId != null) {
      sharing.value = sharing.value.copyWith(
        accuracyMeters: position.accuracy,
        lastFix: now,
        error: null,
      );
    }
    if (_socket == null) return;
    final point = LiveLocationPoint(
      latitude: position.latitude,
      longitude: position.longitude,
      accuracyMeters: position.accuracy,
      timestamp: position.timestamp,
      // Time-based so a restarted app never looks like a replay.
      sequence: now.millisecondsSinceEpoch,
    );
    final journeyId = _journeyId;
    if (journeyId != null) {
      await _sendTo(api, journeyId, _journeyRecipients, point);
    }
    for (final entry in _helping.entries.toList()) {
      await _sendTo(api, entry.key, entry.value, point);
    }
  }

  Future<void> _sendTo(
    DemoApi api,
    String sessionId,
    List<LocationRecipientKeys> recipients,
    LiveLocationPoint point,
  ) async {
    if (recipients.isEmpty) return;
    try {
      final keyring = await E2EKeyring.load(api);
      final envelopes = <Map<String, Object>>[];
      for (final recipient in recipients.take(10)) {
        final envelope = await _cipher.encrypt(
          sessionId: sessionId,
          senderKeyId: keyring.keyId,
          senderSigningKeyPair: keyring.signing,
          recipient: recipient,
          point: point,
        );
        envelopes.add(envelope.toJson());
      }
      _send({'type': 'location', 'envelopes': envelopes});
    } catch (error) {
      debugPrint('LiveLocationRelay could not send a location: $error');
    }
  }
}

class SharingStatus {
  const SharingStatus({
    this.active = false,
    this.recipients = 0,
    this.delivered = 0,
    this.accuracyMeters,
    this.lastFix,
    this.error,
  });

  static const off = SharingStatus();

  final bool active;

  /// Devices I encrypt for (contacts plus helpers on their way).
  final int recipients;

  /// Contact devices that were online for the last fix.
  final int delivered;
  final double? accuracyMeters;
  final DateTime? lastFix;
  final String? error;

  SharingStatus copyWith({
    int? recipients,
    int? delivered,
    double? accuracyMeters,
    DateTime? lastFix,
    String? error,
  }) => SharingStatus(
    active: active,
    recipients: recipients ?? this.recipients,
    delivered: delivered ?? this.delivered,
    accuracyMeters: accuracyMeters ?? this.accuracyMeters,
    lastFix: lastFix ?? this.lastFix,
    error: error,
  );
}
