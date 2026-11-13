import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// The recipient's authenticated public keys, obtained from the identity layer.
/// Callers must verify these keys through the app's trusted key directory.
class LocationRecipientKeys {
  LocationRecipientKeys({
    required this.keyId,
    required this.keyAgreementPublicKey,
  }) {
    _requireId(keyId, 'recipient key id');
    if (keyAgreementPublicKey.type != KeyPairType.x25519 ||
        keyAgreementPublicKey.bytes.length != 32) {
      throw ArgumentError('Recipient key must be a 32-byte X25519 public key.');
    }
  }

  final String keyId;
  final SimplePublicKey keyAgreementPublicKey;
}

/// Authenticated sender signing key from the trusted identity directory.
class LocationSenderVerificationKey {
  LocationSenderVerificationKey({
    required this.keyId,
    required this.signingPublicKey,
  }) {
    _requireId(keyId, 'sender key id');
    if (signingPublicKey.type != KeyPairType.ed25519 ||
        signingPublicKey.bytes.length != 32) {
      throw ArgumentError('Sender key must be a 32-byte Ed25519 public key.');
    }
  }

  final String keyId;
  final SimplePublicKey signingPublicKey;
}

/// A precise location point. It is serialized only inside the encrypted body.
class LiveLocationPoint {
  const LiveLocationPoint({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.timestamp,
    required this.sequence,
  });

  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final DateTime timestamp;
  final int sequence;

  Map<String, Object> toJson() {
    if (!latitude.isFinite || latitude < -90 || latitude > 90) {
      throw ArgumentError.value(latitude, 'latitude');
    }
    if (!longitude.isFinite || longitude < -180 || longitude > 180) {
      throw ArgumentError.value(longitude, 'longitude');
    }
    if (!accuracyMeters.isFinite || accuracyMeters < 0 || sequence < 0) {
      throw ArgumentError('Accuracy and sequence must be non-negative.');
    }
    return {
      'lat': latitude,
      'lon': longitude,
      'accuracy_m': accuracyMeters,
      'timestamp_ms': timestamp.toUtc().millisecondsSinceEpoch,
      'sequence': sequence,
    };
  }

  factory LiveLocationPoint.fromJson(Map<String, dynamic> json) {
    final point = LiveLocationPoint(
      latitude: (json['lat'] as num).toDouble(),
      longitude: (json['lon'] as num).toDouble(),
      accuracyMeters: (json['accuracy_m'] as num).toDouble(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        json['timestamp_ms'] as int,
        isUtc: true,
      ),
      sequence: json['sequence'] as int,
    );
    point.toJson();
    return point;
  }
}

/// One voice clip inside an audio envelope: what kind, its order, and the AAC bytes.
/// Layout: 4-byte big-endian length of a small JSON header, the header, then the audio.
class AudioClip {
  const AudioClip({
    required this.kind,
    required this.sequence,
    required this.recordedAt,
    required this.audio,
  });

  /// `sos` (recording after an SOS) or `escort` (Audio Escort).
  final String kind;
  final int sequence;
  final DateTime recordedAt;
  final List<int> audio;

  List<int> toBytes() {
    final meta = utf8.encode(
      jsonEncode({
        'kind': kind,
        'sequence': sequence,
        'recorded_at_ms': recordedAt.toUtc().millisecondsSinceEpoch,
      }),
    );
    final length = meta.length;
    return [
      (length >> 24) & 0xFF,
      (length >> 16) & 0xFF,
      (length >> 8) & 0xFF,
      length & 0xFF,
      ...meta,
      ...audio,
    ];
  }

  factory AudioClip.fromBytes(List<int> bytes) {
    if (bytes.length < 4) {
      throw const FormatException('Audio clip is too short.');
    }
    final length =
        (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
    if (length <= 0 || length > 1024 || bytes.length < 4 + length) {
      throw const FormatException('Audio clip header is invalid.');
    }
    final meta = jsonDecode(
      utf8.decode(bytes.sublist(4, 4 + length)),
    ) as Map<String, dynamic>;
    final kind = meta['kind'];
    if (kind != 'sos' && kind != 'escort') {
      throw const FormatException('Audio clip kind is invalid.');
    }
    return AudioClip(
      kind: kind as String,
      sequence: meta['sequence'] as int,
      recordedAt: DateTime.fromMillisecondsSinceEpoch(
        meta['recorded_at_ms'] as int,
        isUtc: true,
      ),
      audio: bytes.sublist(4 + length),
    );
  }
}

/// Versioned, signed ciphertext envelope for one recipient and one location.
/// Metadata contains identifiers only; coordinates and time are encrypted.
class LiveLocationEnvelope {
  const LiveLocationEnvelope({
    required this.version,
    required this.sessionId,
    required this.senderKeyId,
    required this.recipientKeyId,
    required this.ephemeralPublicKey,
    required this.nonce,
    required this.ciphertext,
    required this.mac,
    required this.signature,
  });

  final int version;
  final String sessionId;
  final String senderKeyId;
  final String recipientKeyId;
  final String ephemeralPublicKey;
  final String nonce;
  final String ciphertext;
  final String mac;
  final String signature;

  Map<String, Object> toJson() => {
    'v': version,
    'session_id': sessionId,
    'sender_key_id': senderKeyId,
    'recipient_key_id': recipientKeyId,
    'ephemeral_public_key': ephemeralPublicKey,
    'nonce': nonce,
    'ciphertext': ciphertext,
    'mac': mac,
    'signature': signature,
  };

  factory LiveLocationEnvelope.fromJson(Map<String, dynamic> json) {
    if (json['v'] != 1) {
      throw const FormatException('Unsupported envelope version.');
    }
    return LiveLocationEnvelope(
      version: 1,
      sessionId: json['session_id'] as String,
      senderKeyId: json['sender_key_id'] as String,
      recipientKeyId: json['recipient_key_id'] as String,
      ephemeralPublicKey: json['ephemeral_public_key'] as String,
      nonce: json['nonce'] as String,
      ciphertext: json['ciphertext'] as String,
      mac: json['mac'] as String,
      signature: json['signature'] as String,
    );
  }
}

/// Encrypts each location separately for an authenticated recipient.
///
/// X25519 derives a per-message key, HKDF-SHA256 separates it for this
/// protocol/session, AES-256-GCM authenticates the ciphertext and header, and
/// Ed25519 authenticates the sender. Private identity keys and recipient-key
/// verification are supplied by the caller and must come from secure storage
/// and the authenticated identity directory respectively.
class LiveLocationCipher {
  LiveLocationCipher({X25519? x25519, AesGcm? aesGcm, Ed25519? ed25519})
    : _x25519 = x25519 ?? X25519(),
      _aesGcm = aesGcm ?? AesGcm.with256bits(),
      _ed25519 = ed25519 ?? Ed25519();

  static const protocolInfo = 'sixthsense/live-location/v1';

  final X25519 _x25519;
  final AesGcm _aesGcm;
  final Ed25519 _ed25519;

  /// Separate key derivation for audio, so a clip can never be read as a location or back.
  static const audioProtocolInfo = 'sixthsense/audio-clip/v1';

  Future<LiveLocationEnvelope> encrypt({
    required String sessionId,
    required String senderKeyId,
    required KeyPair senderSigningKeyPair,
    required LocationRecipientKeys recipient,
    required LiveLocationPoint point,
  }) => _seal(
    info: protocolInfo,
    sessionId: sessionId,
    senderKeyId: senderKeyId,
    senderSigningKeyPair: senderSigningKeyPair,
    recipient: recipient,
    clearText: utf8.encode(jsonEncode(point.toJson())),
  );

  Future<LiveLocationPoint> decrypt({
    required LiveLocationEnvelope envelope,
    required String expectedSessionId,
    required String expectedRecipientKeyId,
    required KeyPair recipientKeyPair,
    required LocationSenderVerificationKey sender,
    int? lastAcceptedSequence,
  }) async {
    final clearText = await _open(
      info: protocolInfo,
      envelope: envelope,
      expectedSessionId: expectedSessionId,
      expectedRecipientKeyId: expectedRecipientKeyId,
      recipientKeyPair: recipientKeyPair,
      sender: sender,
    );
    final point = LiveLocationPoint.fromJson(
      jsonDecode(utf8.decode(clearText)) as Map<String, dynamic>,
    );
    if (lastAcceptedSequence != null &&
        point.sequence <= lastAcceptedSequence) {
      throw const FormatException('Location point is stale or replayed.');
    }
    return point;
  }

  /// One AAC voice clip (SOS recording or Audio Escort), same scheme as locations.
  Future<LiveLocationEnvelope> encryptAudio({
    required String sessionId,
    required String senderKeyId,
    required KeyPair senderSigningKeyPair,
    required LocationRecipientKeys recipient,
    required AudioClip clip,
  }) => _seal(
    info: audioProtocolInfo,
    sessionId: sessionId,
    senderKeyId: senderKeyId,
    senderSigningKeyPair: senderSigningKeyPair,
    recipient: recipient,
    clearText: clip.toBytes(),
  );

  Future<AudioClip> decryptAudio({
    required LiveLocationEnvelope envelope,
    required String expectedSessionId,
    required String expectedRecipientKeyId,
    required KeyPair recipientKeyPair,
    required LocationSenderVerificationKey sender,
  }) async => AudioClip.fromBytes(
    await _open(
      info: audioProtocolInfo,
      envelope: envelope,
      expectedSessionId: expectedSessionId,
      expectedRecipientKeyId: expectedRecipientKeyId,
      recipientKeyPair: recipientKeyPair,
      sender: sender,
    ),
  );

  Future<LiveLocationEnvelope> _seal({
    required String info,
    required String sessionId,
    required String senderKeyId,
    required KeyPair senderSigningKeyPair,
    required LocationRecipientKeys recipient,
    required List<int> clearText,
  }) async {
    _requireId(sessionId, 'session id');
    _requireId(senderKeyId, 'sender key id');
    final ephemeralKeyPair = await _x25519.newKeyPair();
    try {
      final ephemeralPublicKey = await ephemeralKeyPair.extractPublicKey();
      final header = _header(
        sessionId: sessionId,
        senderKeyId: senderKeyId,
        recipientKeyId: recipient.keyId,
        ephemeralPublicKey: _encode(ephemeralPublicKey.bytes),
      );
      final headerBytes = utf8.encode(jsonEncode(header));
      final sharedSecret = await _x25519.sharedSecretKey(
        keyPair: ephemeralKeyPair,
        remotePublicKey: recipient.keyAgreementPublicKey,
      );
      final encryptionKey = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
          .deriveKey(
            secretKey: sharedSecret,
            nonce: ephemeralPublicKey.bytes,
            info: utf8.encode('$info|$sessionId|${recipient.keyId}'),
          );
      final secretBox = await _aesGcm.encrypt(
        clearText,
        secretKey: encryptionKey,
        aad: headerBytes,
      );
      final signingInput = _signingInput(headerBytes, secretBox);
      final signature = await _ed25519.sign(
        signingInput,
        keyPair: senderSigningKeyPair,
      );
      encryptionKey.destroy();
      return LiveLocationEnvelope(
        version: 1,
        sessionId: sessionId,
        senderKeyId: senderKeyId,
        recipientKeyId: recipient.keyId,
        ephemeralPublicKey: _encode(ephemeralPublicKey.bytes),
        nonce: _encode(secretBox.nonce),
        ciphertext: _encode(secretBox.cipherText),
        mac: _encode(secretBox.mac.bytes),
        signature: _encode(signature.bytes),
      );
    } finally {
      ephemeralKeyPair.destroy();
    }
  }

  Future<List<int>> _open({
    required String info,
    required LiveLocationEnvelope envelope,
    required String expectedSessionId,
    required String expectedRecipientKeyId,
    required KeyPair recipientKeyPair,
    required LocationSenderVerificationKey sender,
  }) async {
    if (envelope.version != 1 ||
        envelope.sessionId != expectedSessionId ||
        envelope.recipientKeyId != expectedRecipientKeyId ||
        envelope.senderKeyId != sender.keyId) {
      throw const FormatException('Location envelope context did not match.');
    }
    final headerBytes = utf8.encode(
      jsonEncode(
        _header(
          sessionId: envelope.sessionId,
          senderKeyId: envelope.senderKeyId,
          recipientKeyId: envelope.recipientKeyId,
          ephemeralPublicKey: envelope.ephemeralPublicKey,
        ),
      ),
    );
    final secretBox = SecretBox(
      _decode(envelope.ciphertext),
      nonce: _decode(envelope.nonce),
      mac: Mac(_decode(envelope.mac)),
    );
    final signature = Signature(
      _decode(envelope.signature),
      publicKey: sender.signingPublicKey,
    );
    final signatureValid = await _ed25519.verify(
      _signingInput(headerBytes, secretBox),
      signature: signature,
    );
    if (!signatureValid) {
      throw const FormatException('Sender signature is invalid.');
    }

    final ephemeralPublicKey = SimplePublicKey(
      _decode(envelope.ephemeralPublicKey),
      type: KeyPairType.x25519,
    );
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: recipientKeyPair,
      remotePublicKey: ephemeralPublicKey,
    );
    final encryptionKey = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(
          secretKey: sharedSecret,
          nonce: ephemeralPublicKey.bytes,
          info: utf8.encode('$info|$expectedSessionId|$expectedRecipientKeyId'),
        );
    try {
      return await _aesGcm.decrypt(
        secretBox,
        secretKey: encryptionKey,
        aad: headerBytes,
      );
    } finally {
      encryptionKey.destroy();
    }
  }

  Map<String, Object> _header({
    required String sessionId,
    required String senderKeyId,
    required String recipientKeyId,
    required String ephemeralPublicKey,
  }) => {
    'v': 1,
    'session_id': sessionId,
    'sender_key_id': senderKeyId,
    'recipient_key_id': recipientKeyId,
    'ephemeral_public_key': ephemeralPublicKey,
  };

  List<int> _signingInput(List<int> header, SecretBox box) => [
    ...header,
    0,
    ...box.nonce,
    ...box.cipherText,
    ...box.mac.bytes,
  ];

  String _encode(List<int> bytes) => base64UrlEncode(bytes);

  List<int> _decode(String value) {
    try {
      return base64Url.decode(base64Url.normalize(value));
    } on FormatException {
      throw const FormatException(
        'Location envelope contains invalid encoding.',
      );
    }
  }
}

void _requireId(String value, String label) {
  if (value.isEmpty || value.length > 128) {
    throw ArgumentError('$label must be between 1 and 128 characters.');
  }
}
