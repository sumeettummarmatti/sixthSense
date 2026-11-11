import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sixthsense_app/core/crypto/live_location_cipher.dart';

void main() {
  late LiveLocationCipher cipher;
  late KeyPair recipientKeyPair;
  late KeyPair senderSigningKeyPair;
  late LocationRecipientKeys recipient;
  late LocationSenderVerificationKey sender;
  late LiveLocationPoint point;

  setUp(() async {
    cipher = LiveLocationCipher();
    recipientKeyPair = await X25519().newKeyPair();
    senderSigningKeyPair = await Ed25519().newKeyPair();
    recipient = LocationRecipientKeys(
      keyId: 'contact-key-7',
      keyAgreementPublicKey:
          await recipientKeyPair.extractPublicKey() as SimplePublicKey,
    );
    sender = LocationSenderVerificationKey(
      keyId: 'traveller-signing-key-2',
      signingPublicKey:
          await senderSigningKeyPair.extractPublicKey() as SimplePublicKey,
    );
    point = LiveLocationPoint(
      latitude: 12.9716,
      longitude: 77.5946,
      accuracyMeters: 8.5,
      timestamp: DateTime.utc(2026, 11, 11, 9, 30),
      sequence: 42,
    );
  });

  test(
    'round trips a signed point without exposing location metadata',
    () async {
      final envelope = await cipher.encrypt(
        sessionId: 'journey-opaque-id',
        senderKeyId: sender.keyId,
        senderSigningKeyPair: senderSigningKeyPair,
        recipient: recipient,
        point: point,
      );

      final serialized = jsonEncode(envelope.toJson());
      expect(serialized, isNot(contains('12.9716')));
      expect(serialized, isNot(contains('77.5946')));
      expect(
        serialized,
        isNot(contains(point.timestamp.millisecondsSinceEpoch.toString())),
      );

      final decodedEnvelope = LiveLocationEnvelope.fromJson(
        jsonDecode(serialized) as Map<String, dynamic>,
      );
      final clearPoint = await cipher.decrypt(
        envelope: decodedEnvelope,
        expectedSessionId: 'journey-opaque-id',
        expectedRecipientKeyId: recipient.keyId,
        recipientKeyPair: recipientKeyPair,
        sender: sender,
      );
      expect(clearPoint.latitude, point.latitude);
      expect(clearPoint.longitude, point.longitude);
      expect(clearPoint.accuracyMeters, point.accuracyMeters);
      expect(clearPoint.timestamp, point.timestamp);
      expect(clearPoint.sequence, point.sequence);
    },
  );

  test('rejects a modified envelope before decrypting it', () async {
    final envelope = await cipher.encrypt(
      sessionId: 'journey-opaque-id',
      senderKeyId: sender.keyId,
      senderSigningKeyPair: senderSigningKeyPair,
      recipient: recipient,
      point: point,
    );
    final tampered = LiveLocationEnvelope.fromJson({
      ...envelope.toJson(),
      'ciphertext': base64UrlEncode([1, 2, 3]),
    });

    await expectLater(
      cipher.decrypt(
        envelope: tampered,
        expectedSessionId: 'journey-opaque-id',
        expectedRecipientKeyId: recipient.keyId,
        recipientKeyPair: recipientKeyPair,
        sender: sender,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects the wrong session, recipient, and replayed sequence', () async {
    final envelope = await cipher.encrypt(
      sessionId: 'journey-opaque-id',
      senderKeyId: sender.keyId,
      senderSigningKeyPair: senderSigningKeyPair,
      recipient: recipient,
      point: point,
    );

    Future<LiveLocationPoint> decrypt({
      String sessionId = 'journey-opaque-id',
      String recipientKeyId = 'contact-key-7',
      int? lastSequence,
    }) => cipher.decrypt(
      envelope: envelope,
      expectedSessionId: sessionId,
      expectedRecipientKeyId: recipientKeyId,
      recipientKeyPair: recipientKeyPair,
      sender: sender,
      lastAcceptedSequence: lastSequence,
    );

    await expectLater(
      decrypt(sessionId: 'another-session'),
      throwsFormatException,
    );
    await expectLater(
      decrypt(recipientKeyId: 'another-key'),
      throwsFormatException,
    );
    await expectLater(decrypt(lastSequence: 42), throwsFormatException);
  });
}
