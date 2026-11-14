import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sixthsense_app/core/api/device_identity.dart';
import 'package:sixthsense_app/core/crypto/live_location_cipher.dart';
import 'package:sixthsense_app/core/sos/sudden_sos.dart';
import 'package:sixthsense_app/features/journey/journey_flow.dart';
import 'package:sixthsense_app/features/sos/sos_widgets.dart';

void main() {
  group('audio clip encryption', () {
    late LiveLocationCipher cipher;
    late KeyPair recipientKeyPair;
    late KeyPair signing;
    late LocationRecipientKeys recipient;
    late LocationSenderVerificationKey sender;
    final clip = AudioClip(
      kind: 'sos',
      sequence: 3,
      recordedAt: DateTime.utc(2026, 11, 13, 22, 10),
      audio: List<int>.generate(15000, (i) => i % 251),
    );

    setUp(() async {
      cipher = LiveLocationCipher();
      recipientKeyPair = await X25519().newKeyPair();
      signing = await Ed25519().newKeyPair();
      recipient = LocationRecipientKeys(
        keyId: 'contact-key',
        keyAgreementPublicKey:
            await recipientKeyPair.extractPublicKey() as SimplePublicKey,
      );
      sender = LocationSenderVerificationKey(
        keyId: 'traveller-key',
        signingPublicKey: await signing.extractPublicKey() as SimplePublicKey,
      );
    });

    test('a clip round trips and fits the relay limit', () async {
      final envelope = await cipher.encryptAudio(
        sessionId: 'journey-1',
        senderKeyId: sender.keyId,
        senderSigningKeyPair: signing,
        recipient: recipient,
        clip: clip,
      );
      expect(envelope.ciphertext.length, lessThan(65536));
      final opened = await cipher.decryptAudio(
        envelope: envelope,
        expectedSessionId: 'journey-1',
        expectedRecipientKeyId: 'contact-key',
        recipientKeyPair: recipientKeyPair,
        sender: sender,
      );
      expect(opened.kind, 'sos');
      expect(opened.sequence, 3);
      expect(opened.audio, clip.audio);
    });

    test('audio and location keys are kept apart', () async {
      final audio = await cipher.encryptAudio(
        sessionId: 'journey-1',
        senderKeyId: sender.keyId,
        senderSigningKeyPair: signing,
        recipient: recipient,
        clip: clip,
      );
      await expectLater(
        cipher.decrypt(
          envelope: audio,
          expectedSessionId: 'journey-1',
          expectedRecipientKeyId: 'contact-key',
          recipientKeyPair: recipientKeyPair,
          sender: sender,
        ),
        throwsA(anything),
      );
    });

    test('a clip from another journey is refused', () async {
      final envelope = await cipher.encryptAudio(
        sessionId: 'journey-1',
        senderKeyId: sender.keyId,
        senderSigningKeyPair: signing,
        recipient: recipient,
        clip: clip,
      );
      await expectLater(
        cipher.decryptAudio(
          envelope: envelope,
          expectedSessionId: 'journey-2',
          expectedRecipientKeyId: 'contact-key',
          recipientKeyPair: recipientKeyPair,
          sender: sender,
        ),
        throwsFormatException,
      );
    });

    test('clip framing rejects junk', () {
      expect(
        AudioClip.fromBytes(clip.toBytes()).audio.length,
        clip.audio.length,
      );
      expect(() => AudioClip.fromBytes([0, 0]), throwsFormatException);
      final wrongKind = AudioClip(
        kind: 'sos',
        sequence: 1,
        recordedAt: DateTime.utc(2026),
        audio: const [1],
      ).toBytes();
      // Flip "sos" to "sOs" inside the header.
      final index = String.fromCharCodes(wrongKind).indexOf('sos');
      wrongKind[index + 1] = 'O'.codeUnitAt(0);
      expect(() => AudioClip.fromBytes(wrongKind), throwsFormatException);
    });
  });

  group('phone events', () {
    tearDown(() => SuddenSos.instance.countdown.value = null);

    test('a countdown shows until it is cancelled or sent', () {
      final sos = SuddenSos.instance;
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      sos.handleEvent('countdown', {
        'deadlineMillis': deadline.millisecondsSinceEpoch,
        'source': 'voice',
        'heard': 'बचाओ',
      });
      expect(sos.countdown.value?.source, 'voice');
      expect(sos.countdown.value?.heard, 'बचाओ');
      expect(
        sos.countdown.value!.secondsLeft(DateTime.now()),
        inInclusiveRange(4, 5),
      );
      sos.handleEvent('fired', {'serverOk': true});
      expect(sos.countdown.value, isNull);

      sos.handleEvent('showCountdown', {
        'state': 'armed',
        'deadlineMillis': deadline.millisecondsSinceEpoch,
      });
      expect(sos.countdown.value, isNull, reason: 'no countdown when armed');
    });
  });

  group('widgets', () {
    testWidgets('countdown overlay explains itself and offers the PIN', (
      tester,
    ) async {
      var asked = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            children: [
              SosCountdownOverlay(
                countdown: SosCountdown(
                  deadline: DateTime.now().add(const Duration(seconds: 5)),
                  source: 'button',
                  heard: 'volume',
                ),
                onEnterPin: () => asked++,
              ),
            ],
          ),
        ),
      );
      expect(find.textContaining('Sending SOS in'), findsOneWidget);
      expect(find.textContaining('volume buttons'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sos-cancel')));
      expect(asked, 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('escort panel: start, answer a request, stop', (tester) async {
      final started = <String?>[];
      final declined = <String>[];
      var stopped = 0;
      Widget panel({
        Escort? escort,
        List<EscortRequestView> requests = const [],
      }) => MaterialApp(
        home: Scaffold(
          body: EscortPanel(
            escort: escort,
            requests: requests,
            names: const {},
            onStart: started.add,
            onDecline: declined.add,
            onStop: () => stopped++,
          ),
        ),
      );

      await tester.pumpWidget(panel());
      await tester.tap(find.byKey(const ValueKey('escort-start')));
      expect(started, [null]);

      await tester.pumpWidget(
        panel(
          requests: const [
            EscortRequestView(id: 'req-1', contactLinkId: 'link-1'),
          ],
        ),
      );
      expect(find.textContaining('asks to keep you company'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('escort-accept')));
      await tester.tap(find.text('No thanks'));
      expect(started, [null, 'req-1']);
      expect(declined, ['req-1']);

      await tester.pumpWidget(
        panel(
          escort: Escort(
            id: 'e1',
            journeyId: 'j1',
            endsAt: DateTime(2026, 11, 13, 23, 30),
            listenerLinkIds: const ['link-1'],
          ),
        ),
      );
      expect(find.textContaining('Audio escort on'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('escort-stop')));
      expect(stopped, 1);
    });
  });

  group('journey with a sudden SOS', () {
    late List<MethodCall> sosCalls;

    setUp(() {
      sosCalls = [];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('in.sixthsense/journey_runtime'),
        (call) async => null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('in.sixthsense/sudden_sos'),
        (call) async {
          sosCalls.add(call);
          return switch (call.method) {
            'requestMicPermission' || 'fireNow' || 'cancelCountdown' => true,
            'takeClips' || 'voiceModels' => null,
            _ => null,
          };
        },
      );
    });

    tearDown(() {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('in.sixthsense/journey_runtime'),
        null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('in.sixthsense/sudden_sos'),
        null,
      );
      SuddenSos.instance.countdown.value = null;
    });

    Future<void> startJourney(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(home: JourneyFlow(api: _FakeApi())));
      await tester.enterText(
        find.byKey(const ValueKey('journey-destination')),
        'Library',
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('journey-real-pin')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byKey(const ValueKey('journey-real-pin')),
        '1234',
      );
      await tester.enterText(
        find.byKey(const ValueKey('journey-duress-pin')),
        '5678',
      );
      expect(find.byKey(const ValueKey('record-audio-switch')), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Start journey'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Start journey'));
      await tester.pumpAndSettle();
      expect(find.text('until your next check-in'), findsOneWidget);
      // The phone got what it needs to send an SOS by itself.
      expect(sosCalls.map((c) => c.method), contains('requestMicPermission'));
    }

    void countdown() => SuddenSos.instance.handleEvent('countdown', {
      'deadlineMillis': DateTime.now()
          .add(const Duration(seconds: 5))
          .millisecondsSinceEpoch,
      'source': 'button',
      'heard': 'volume',
    });

    Future<void> enterPin(WidgetTester tester, String pin) async {
      await tester.tap(find.byKey(const ValueKey('sos-cancel')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('sos-pin')), pin);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
    }

    testWidgets('the real PIN cancels the countdown', (tester) async {
      await startJourney(tester);
      countdown();
      await tester.pump();
      expect(find.byKey(const ValueKey('sos-countdown')), findsOneWidget);
      await enterPin(tester, '1234');
      expect(find.byKey(const ValueKey('sos-countdown')), findsNothing);
      expect(sosCalls.last.method, 'cancelCountdown');
      expect(find.text('SOS cancelled.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the duress PIN looks the same but sends a silent alarm', (
      tester,
    ) async {
      await startJourney(tester);
      countdown();
      await tester.pump();
      await enterPin(tester, '5678');
      expect(find.byKey(const ValueKey('sos-countdown')), findsNothing);
      expect(find.text('SOS cancelled.'), findsOneWidget);
      final fire = sosCalls.lastWhere((c) => c.method == 'fireNow');
      expect((fire.arguments as Map)['covert'], isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a wrong PIN keeps counting down', (tester) async {
      await startJourney(tester);
      countdown();
      await tester.pump();
      await enterPin(tester, '0000');
      expect(find.byKey(const ValueKey('sos-countdown')), findsOneWidget);
      expect(sosCalls.map((c) => c.method), isNot(contains('cancelCountdown')));
      SuddenSos.instance.countdown.value = null;
      await tester.pumpWidget(const SizedBox());
    });
  });
}

class _FakeApi extends DemoApi {
  @override
  Future<JourneySnapshot> startJourney(int checkInIntervalMinutes) async =>
      JourneySnapshot(
        id: 'journey-1',
        state: 'active',
        nextCheckInAt: DateTime.now().add(
          Duration(minutes: checkInIntervalMinutes),
        ),
        heartbeatTimeoutMinutes: 10,
      );
}
