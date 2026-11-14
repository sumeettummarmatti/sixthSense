import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:sixthsense_app/core/api/device_identity.dart';
import 'package:sixthsense_app/features/respond/respond_screen.dart';
import 'package:sixthsense_app/features/verification/id_field_ocr.dart';
import 'package:sixthsense_app/features/verification/verification_flow.dart';

void main() {
  testWidgets('an incomplete session is not shown as waiting for review', (
    tester,
  ) async {
    useTallTestView(tester);
    await tester.pumpWidget(
      MaterialApp(home: _verificationScreen(_NotSubmittedVerificationApi())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Choose your ID'), findsOneWidget);
    expect(find.text('Not submitted'), findsOneWidget);
    expect(find.text('Email sign-in'), findsOneWidget);
    expect(find.text('Face match'), findsOneWidget);
    expect(find.text('Ready to help'), findsOneWidget);
    expect(find.text('Waiting for review'), findsNothing);
  });

  testWidgets(
    'consent is required before starting and the SIMULATED banner shows',
    (tester) async {
      useTallTestView(tester);
      await tester.pumpWidget(
        MaterialApp(home: _verificationScreen(_FakeVerificationApi())),
      );
      await tester.pumpAndSettle();

      expect(find.text('Before you begin'), findsOneWidget);
      expect(find.text('DEMO CHECK · FACE MATCH ONLY'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('verification-consent')));
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Choose your ID'), findsOneWidget);
    },
  );

  testWidgets('underage result says protection features still work', (
    tester,
  ) async {
    useTallTestView(tester);
    final api = _FakeVerificationApi(result: 'underage');
    await tester.pumpWidget(MaterialApp(home: _verificationScreen(api)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('verification-consent')));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Choose your ID'), findsOneWidget);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Enter sample details'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('sample-id-number')),
      'DEMO-12345',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sample-dob')),
      '2012-01-01',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Upload ID photo'));
    await tester.tap(find.text('Upload ID photo'));
    await tester.pumpAndSettle();
    await _waitForIdOcr(tester);
    expect(find.text('Choose another ID photo'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Continue to selfie check'));
    await tester.tap(find.text('Continue to selfie check'));
    await tester.pumpAndSettle();
    expect(find.text('Selfie check'), findsOneWidget);

    await tester.tap(find.text('Take selfie'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await _openConfirmation(tester);
    await tester.tap(find.text('Confirm and compare faces'));
    await tester.pumpAndSettle();
    expect(find.text('You can’t respond as a helper yet'), findsOneWidget);
    expect(
      find.textContaining('Your protection features still work'),
      findsOneWidget,
    );
    expect(find.text('DEMO CHECK · FACE MATCH ONLY'), findsOneWidget);
  });

  testWidgets('debug build exposes the scenario picker', (tester) async {
    useTallTestView(tester);
    await tester.pumpWidget(
      MaterialApp(home: _verificationScreen(_FakeVerificationApi())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('verification-consent')));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('sample-id-number')),
      'DEMO-12345',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sample-dob')),
      '2000-01-01',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Upload ID photo'));
    await tester.tap(find.text('Upload ID photo'));
    await tester.pumpAndSettle();
    await _waitForIdOcr(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Continue to selfie check'));
    await tester.tap(find.text('Continue to selfie check'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('verification-scenario-picker')),
      kDebugMode ? findsOneWidget : findsNothing,
    );
  });

  testWidgets('ID details and ID photo are required before selfie', (
    tester,
  ) async {
    useTallTestView(tester);
    await tester.pumpWidget(
      MaterialApp(home: _verificationScreen(_FakeVerificationApi())),
    );
    await tester.pumpAndSettle();
    await _openDocumentStep(tester);

    FilledButton documentContinue() => tester.widget<FilledButton>(
      find.byKey(const ValueKey('verification-document-continue')),
    );

    expect(documentContinue().onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('sample-id-number')),
      'DEMO-12345',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sample-dob')),
      '2999-01-01',
    );
    await tester.pump();
    expect(documentContinue().onPressed, isNull);

    await tester.enterText(
      find.byKey(const ValueKey('sample-dob')),
      '2000-02-31',
    );
    await tester.pump();
    expect(documentContinue().onPressed, isNull);

    await tester.enterText(
      find.byKey(const ValueKey('sample-dob')),
      '2000-01-01',
    );
    await tester.pump();
    expect(documentContinue().onPressed, isNull);
    await tester.ensureVisible(find.text('Upload ID photo'));
    await tester.tap(find.text('Upload ID photo'));
    await tester.pumpAndSettle();
    await _waitForIdOcr(tester);
    expect(documentContinue().onPressed, isNotNull);
  });

  testWidgets('selfie is required before face comparison', (tester) async {
    useTallTestView(tester);
    await tester.pumpWidget(
      MaterialApp(home: _verificationScreen(_FakeVerificationApi())),
    );
    await tester.pumpAndSettle();
    await _openDocumentStep(tester);
    await tester.enterText(
      find.byKey(const ValueKey('sample-id-number')),
      'DEMO-12345',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sample-dob')),
      '2000-01-01',
    );
    await tester.ensureVisible(find.text('Upload ID photo'));
    await tester.tap(find.text('Upload ID photo'));
    await tester.pumpAndSettle();
    await _waitForIdOcr(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey('verification-document-continue')),
    );
    await tester.tap(
      find.byKey(const ValueKey('verification-document-continue')),
    );
    await tester.pumpAndSettle();

    FilledButton reviewButton() => tester.widget<FilledButton>(
      find.byKey(const ValueKey('verification-review-details')),
    );

    expect(reviewButton().onPressed, isNull);
    await tester.tap(find.text('Take selfie'));
    await tester.pumpAndSettle();
    expect(reviewButton().onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('verification-review-details')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('verification-submit')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(
      find.byKey(const ValueKey('verification-confirm-details')),
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('verification-submit')),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('expired draft restoration explains the next action', (
    tester,
  ) async {
    useTallTestView(tester);
    await tester.pumpWidget(
      MaterialApp(home: _verificationScreen(_ExpiredDraftVerificationApi())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Verification expired'), findsOneWidget);
    expect(find.text('Start a new attempt'), findsOneWidget);
    expect(find.text('Waiting for review'), findsNothing);
  });

  testWidgets('expired submission opens the expiry result and retry action', (
    tester,
  ) async {
    useTallTestView(tester);
    await tester.pumpWidget(
      MaterialApp(home: _verificationScreen(_ExpiredSubmitVerificationApi())),
    );
    await tester.pumpAndSettle();
    await _openDocumentStep(tester);
    await tester.enterText(
      find.byKey(const ValueKey('sample-id-number')),
      'DEMO-12345',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sample-dob')),
      '2000-01-01',
    );
    await tester.ensureVisible(find.text('Upload ID photo'));
    await tester.tap(find.text('Upload ID photo'));
    await tester.pumpAndSettle();
    await _waitForIdOcr(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey('verification-document-continue')),
    );
    await tester.tap(
      find.byKey(const ValueKey('verification-document-continue')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Take selfie'));
    await tester.pumpAndSettle();
    await _openConfirmation(tester);
    await tester.tap(find.text('Confirm and compare faces'));
    await tester.pumpAndSettle();

    expect(find.text('Verification expired'), findsOneWidget);
    expect(find.text('Start a new attempt'), findsOneWidget);
    expect(find.text('Could not complete verification'), findsNothing);
  });

  testWidgets(
    'temporary matcher failure retries without losing submitted data',
    (tester) async {
      useTallTestView(tester);
      final api = _RetryVerificationApi();
      await tester.pumpWidget(MaterialApp(home: _verificationScreen(api)));
      await tester.pumpAndSettle();
      await _prepareForComparison(tester);
      await tester.tap(find.text('Confirm and compare faces'));
      await tester.pumpAndSettle();

      expect(find.text('Could not complete verification'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('retry-face-comparison')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('retry-face-comparison')));
      await tester.pumpAndSettle();

      expect(find.text('Verification complete'), findsOneWidget);
      expect(api.submitCalls, 2);
      expect(api.lastIdNumber, 'DEMO-12345');
      expect(api.lastDateOfBirth, '2000-01-01');
    },
  );

  testWidgets('retry refreshes status before resubmitting a lost response', (
    tester,
  ) async {
    useTallTestView(tester);
    final api = _RetryVerificationApi(responseLostAfterSuccess: true);
    await tester.pumpWidget(MaterialApp(home: _verificationScreen(api)));
    await tester.pumpAndSettle();
    await _prepareForComparison(tester);
    await tester.tap(find.text('Confirm and compare faces'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('retry-face-comparison')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('retry-face-comparison')));
    await tester.pumpAndSettle();

    expect(find.text('Verification complete'), findsOneWidget);
    expect(api.sessionChecks, 1); // The pre-retry refresh.
    expect(
      api.submitCalls,
      1,
    ); // The already completed request is not duplicated.
  });

  testWidgets('selfie capture requests the camera source', (tester) async {
    useTallTestView(tester);
    final requestedSources = <ImageSource>[];
    await tester.pumpWidget(
      MaterialApp(
        home: VerificationFlowScreen(
          api: _FakeVerificationApi(),
          idOcr: OnDeviceIdOcr(readText: (_) async => ''),
          pickPhoto: (source) async {
            requestedSources.add(source);
            return VerificationImage(
              bytes: base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/6+8AAAAASUVORK5CYII=',
              ),
              mimeType: 'image/jpeg',
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _prepareForComparison(tester);

    expect(requestedSources, [ImageSource.gallery, ImageSource.camera]);
  });

  testWidgets('oversized image is rejected before upload', (tester) async {
    useTallTestView(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: VerificationFlowScreen(
          api: _FakeVerificationApi(),
          pickPhoto: (_) async => VerificationImage(
            bytes: Uint8List(5 * 1024 * 1024 + 1),
            mimeType: 'image/jpeg',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _openDocumentStep(tester);
    await tester.enterText(
      find.byKey(const ValueKey('sample-id-number')),
      'DEMO-12345',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sample-dob')),
      '2000-01-01',
    );
    await tester.ensureVisible(find.text('Upload ID photo'));
    await tester.tap(find.text('Upload ID photo'));
    await tester.pumpAndSettle();

    expect(
      find.text('Choose an image that is 5 MB or smaller.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('verification-document-continue')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('unsupported image type gets a clear format message', (
    tester,
  ) async {
    useTallTestView(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: VerificationFlowScreen(
          api: _FakeVerificationApi(),
          pickPhoto: (_) async => VerificationImage(
            bytes: Uint8List.fromList([1, 2, 3]),
            mimeType: 'application/octet-stream',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _openDocumentStep(tester);
    await tester.ensureVisible(find.text('Upload ID photo'));
    await tester.tap(find.text('Upload ID photo'));
    await tester.pumpAndSettle();

    expect(find.text('Choose a JPG, PNG, or WebP image.'), findsOneWidget);
  });

  testWidgets('ID photo autofills only ID number and date of birth', (
    tester,
  ) async {
    useTallTestView(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: _verificationScreen(
          _FakeVerificationApi(),
          idOcr: OnDeviceIdOcr(
            readText: (_) async =>
                'Name: Tanisha Jayabalan\n'
                'Passport No: A1234567\n'
                'Date of Birth: 25/12/2000\n'
                'Address: Bengaluru',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('verification-consent')));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Passport'));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Upload ID photo'));
    await tester.tap(find.text('Upload ID photo'));
    await tester.pumpAndSettle();
    await _waitForIdOcr(tester);

    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('sample-id-number')))
          .controller
          ?.text,
      'A1234567',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('sample-dob')))
          .controller
          ?.text,
      '2000-12-25',
    );
    expect(find.text('SAMPLE · PASSPORT'), findsOneWidget);
    expect(find.textContaining('TANISHA'), findsNothing);
    expect(find.textContaining('Bengaluru'), findsNothing);
    expect(find.text('Suggested ID number'), findsOneWidget);
    expect(find.text('Suggested date of birth'), findsOneWidget);
    expect(find.text('Read from photo. Tap to edit.'), findsNWidgets(2));
    expect(
      find.text(
        'Read available ID details on this device. Check the fields below.',
      ),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('sample-id-number')),
      'A7654321',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sample-dob')),
      '2000-12-26',
    );
    await tester.pump();
    expect(find.text('Sample ID number'), findsOneWidget);
    expect(find.text('Sample date of birth'), findsOneWidget);
    expect(find.text('Suggested ID number'), findsNothing);
    expect(find.text('Suggested date of birth'), findsNothing);
  });

  testWidgets('face comparison requires review and explicit confirmation', (
    tester,
  ) async {
    useTallTestView(tester);
    await tester.pumpWidget(
      MaterialApp(home: _verificationScreen(_FakeVerificationApi())),
    );
    await tester.pumpAndSettle();
    await _prepareForSelfie(tester);
    await tester.tap(find.text('Review details'));
    await tester.pumpAndSettle();

    expect(find.text('Review before face comparison'), findsOneWidget);
    expect(find.text('ID type'), findsOneWidget);
    expect(find.text('Driving Licence'), findsOneWidget);
    expect(find.text('DEMO-12345'), findsOneWidget);
    expect(find.text('2000-01-01'), findsOneWidget);
    expect(find.byKey(const ValueKey('review-id-photo')), findsOneWidget);
    expect(find.byKey(const ValueKey('review-selfie-photo')), findsOneWidget);
    FilledButton confirmButton() => tester.widget<FilledButton>(
      find.byKey(const ValueKey('verification-submit')),
    );

    expect(confirmButton().onPressed, isNull);
    await tester.tap(
      find.byKey(const ValueKey('verification-confirm-details')),
    );
    await tester.pump();
    expect(confirmButton().onPressed, isNotNull);
  });

  testWidgets('OCR does not overwrite details already entered manually', (
    tester,
  ) async {
    useTallTestView(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: _verificationScreen(
          _FakeVerificationApi(),
          idOcr: OnDeviceIdOcr(
            readText: (_) async =>
                'Passport No: A1234567\nDate of Birth: 25/12/2000',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _openDocumentStep(tester);
    await tester.enterText(
      find.byKey(const ValueKey('sample-id-number')),
      'MANUAL-999',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sample-dob')),
      '1999-01-02',
    );
    await tester.ensureVisible(find.text('Upload ID photo'));
    await tester.tap(find.text('Upload ID photo'));
    await tester.pumpAndSettle();
    await _waitForIdOcr(tester);

    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('sample-id-number')))
          .controller
          ?.text,
      'MANUAL-999',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('sample-dob')))
          .controller
          ?.text,
      '1999-01-02',
    );
  });

  testWidgets(
    'invalid face input asks for a retake without losing ID details',
    (tester) async {
      useTallTestView(tester);
      final api = _InvalidFaceInputVerificationApi();
      await tester.pumpWidget(MaterialApp(home: _verificationScreen(api)));
      await tester.pumpAndSettle();
      await _prepareForComparison(tester);
      await tester.tap(find.text('Confirm and compare faces'));
      await tester.pumpAndSettle();

      expect(find.text('Selfie check'), findsOneWidget);
      expect(
        find.textContaining('Use one clear face in each photo.'),
        findsOneWidget,
      );
      expect(find.text('Take selfie'), findsOneWidget);
      await tester.tap(find.text('Take selfie'));
      await tester.pumpAndSettle();
      await _openConfirmation(tester);
      await tester.tap(find.text('Confirm and compare faces'));
      await tester.pumpAndSettle();

      expect(find.text('Verification complete'), findsOneWidget);
      expect(api.lastIdNumber, 'DEMO-12345');
      expect(api.lastDateOfBirth, '2000-01-01');
    },
  );

  testWidgets('face mismatch retry keeps the ID details and portrait', (
    tester,
  ) async {
    useTallTestView(tester);
    final api = _FaceMismatchRetryVerificationApi();
    await tester.pumpWidget(MaterialApp(home: _verificationScreen(api)));
    await tester.pumpAndSettle();
    await _prepareForComparison(tester);
    await tester.tap(find.text('Confirm and compare faces'));
    await tester.pumpAndSettle();

    expect(find.text('Verification not approved'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('retake-after-face-mismatch')));
    await tester.pumpAndSettle();
    expect(find.text('Selfie check'), findsOneWidget);
    await tester.tap(find.text('Take selfie'));
    await tester.pumpAndSettle();
    await _openConfirmation(tester);
    await tester.tap(find.text('Confirm and compare faces'));
    await tester.pumpAndSettle();

    expect(find.text('Verification complete'), findsOneWidget);
    expect(api.createdSessions, 2);
    expect(api.submittedIdNumbers, ['DEMO-12345', 'DEMO-12345']);
    expect(api.idPhotos[0], api.idPhotos[1]);
  });

  testWidgets(
    'unverified responder application can continue to identity check',
    (tester) async {
      useTallTestView(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: RespondScreen(
            api: _PendingResponderApi(),
            pollInterval: const Duration(hours: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Verify your identity to start helping'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('continue-verification')));
      await tester.pumpAndSettle();
      expect(find.text('Before you begin'), findsOneWidget);
    },
  );

  testWidgets('verified responder has no approval stage', (tester) async {
    useTallTestView(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: RespondScreen(
          api: _PendingResponderApi(verificationStatus: 'verified'),
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('approval'), findsNothing);
    expect(find.text('Responder approval pending'), findsNothing);
    expect(find.text('Off duty'), findsOneWidget); // can go on duty right away
  });
}

Future<void> _openDocumentStep(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('verification-consent')));
  await tester.pump();
  await tester.tap(find.text('Continue'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Continue'));
  await tester.pumpAndSettle();
  expect(find.text('Enter sample details'), findsOneWidget);
}

Future<void> _prepareForComparison(WidgetTester tester) async {
  await _prepareForSelfie(tester);
  await _openConfirmation(tester);
}

Future<void> _prepareForSelfie(WidgetTester tester) async {
  await _openDocumentStep(tester);
  await tester.enterText(
    find.byKey(const ValueKey('sample-id-number')),
    'DEMO-12345',
  );
  await tester.enterText(
    find.byKey(const ValueKey('sample-dob')),
    '2000-01-01',
  );
  await tester.ensureVisible(find.text('Upload ID photo'));
  await tester.tap(find.text('Upload ID photo'));
  await tester.pumpAndSettle();
  await _waitForIdOcr(tester);
  await tester.ensureVisible(
    find.byKey(const ValueKey('verification-document-continue')),
  );
  await tester.tap(
    find.byKey(const ValueKey('verification-document-continue')),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Take selfie'));
  await tester.pumpAndSettle();
}

Future<void> _openConfirmation(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Review details'));
  await tester.tap(find.text('Review details'));
  await tester.pumpAndSettle();
  expect(find.text('Review before face comparison'), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('verification-confirm-details')));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('Confirm and compare faces'));
}

Future<void> _waitForIdOcr(WidgetTester tester) async {
  final result = find.byKey(const ValueKey('id-ocr-message'));
  for (var attempt = 0; attempt < 50; attempt++) {
    if (result.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 20));
  }
  fail('ID photo OCR did not finish.');
}

void useTallTestView(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _FakeIdentity extends DeviceIdentity {
  const _FakeIdentity();

  @override
  Future<void> saveValue(String name, String? value) async {}

  @override
  Future<String?> readValue(String name) async => null;
}

class _FakeVerificationApi extends DemoApi {
  _FakeVerificationApi({this.result = 'verified'})
    : super(identity: const _FakeIdentity());

  final String result;

  @override
  Future<Map<String, dynamic>> verificationMe() async => {
    'status': 'not_started',
    'session_id': null,
  };

  @override
  Future<Map<String, dynamic>> createVerificationSession({
    required bool consent,
    bool faceTemplateConsent = false,
  }) async => {'id': 'session-1', 'status': 'not_submitted'};

  @override
  Future<Map<String, dynamic>> submitVerificationSelfie({
    required String sessionId,
    required String idType,
    required String idNumber,
    required String dateOfBirth,
    required VerificationImage idImage,
    required VerificationImage selfieImage,
    String? scenario,
  }) async => {
    'id': sessionId,
    'status': result,
    if (result == 'underage') 'reason_code': 'underage',
  };
}

class _NotSubmittedVerificationApi extends _FakeVerificationApi {
  @override
  Future<Map<String, dynamic>> verificationMe() async => {
    'status': 'not_submitted',
    'session_id': 'session-1',
  };

  @override
  Future<Map<String, dynamic>> verificationSession(String sessionId) async => {
    'id': sessionId,
    'status': 'not_submitted',
  };
}

class _ExpiredDraftVerificationApi extends _FakeVerificationApi {
  @override
  Future<Map<String, dynamic>> verificationMe() async => {
    'status': 'expired',
    'session_id': 'expired-session',
    'reason_code': 'session_expired',
  };

  @override
  Future<Map<String, dynamic>> verificationSession(String sessionId) async => {
    'id': sessionId,
    'status': 'expired',
    'reason_code': 'session_expired',
  };
}

class _ExpiredSubmitVerificationApi extends _FakeVerificationApi {
  @override
  Future<Map<String, dynamic>> submitVerificationSelfie({
    required String sessionId,
    required String idType,
    required String idNumber,
    required String dateOfBirth,
    required VerificationImage idImage,
    required VerificationImage selfieImage,
    String? scenario,
  }) async => throw const ApiException(409, 'verification_session_not_pending');
}

class _InvalidFaceInputVerificationApi extends _FakeVerificationApi {
  var submissions = 0;
  String? lastIdNumber;
  String? lastDateOfBirth;

  @override
  Future<Map<String, dynamic>> submitVerificationSelfie({
    required String sessionId,
    required String idType,
    required String idNumber,
    required String dateOfBirth,
    required VerificationImage idImage,
    required VerificationImage selfieImage,
    String? scenario,
  }) async {
    submissions++;
    lastIdNumber = idNumber;
    lastDateOfBirth = dateOfBirth;
    if (submissions == 1) {
      throw const ApiException(422, 'face_image_invalid');
    }
    return {'id': sessionId, 'status': 'verified'};
  }
}

class _FaceMismatchRetryVerificationApi extends _FakeVerificationApi {
  var createdSessions = 0;
  var submissions = 0;
  final submittedIdNumbers = <String>[];
  final idPhotos = <List<int>>[];

  @override
  Future<Map<String, dynamic>> createVerificationSession({
    required bool consent,
    bool faceTemplateConsent = false,
  }) async {
    createdSessions++;
    return {'id': 'session-$createdSessions', 'status': 'not_submitted'};
  }

  @override
  Future<Map<String, dynamic>> submitVerificationSelfie({
    required String sessionId,
    required String idType,
    required String idNumber,
    required String dateOfBirth,
    required VerificationImage idImage,
    required VerificationImage selfieImage,
    String? scenario,
  }) async {
    submissions++;
    submittedIdNumbers.add(idNumber);
    idPhotos.add(idImage.bytes);
    if (submissions == 1) {
      return {
        'id': sessionId,
        'status': 'rejected',
        'reason_code': 'face_mismatch',
      };
    }
    return {'id': sessionId, 'status': 'verified'};
  }
}

class _RetryVerificationApi extends _FakeVerificationApi {
  _RetryVerificationApi({this.responseLostAfterSuccess = false});

  final bool responseLostAfterSuccess;
  var submitCalls = 0;
  var sessionChecks = 0;
  var completed = false;
  String? lastIdNumber;
  String? lastDateOfBirth;

  @override
  Future<Map<String, dynamic>> verificationSession(String sessionId) async {
    sessionChecks++;
    return {
      'id': sessionId,
      'status': completed ? 'verified' : 'not_submitted',
    };
  }

  @override
  Future<Map<String, dynamic>> submitVerificationSelfie({
    required String sessionId,
    required String idType,
    required String idNumber,
    required String dateOfBirth,
    required VerificationImage idImage,
    required VerificationImage selfieImage,
    String? scenario,
  }) async {
    submitCalls++;
    lastIdNumber = idNumber;
    lastDateOfBirth = dateOfBirth;
    if (submitCalls == 1) {
      if (responseLostAfterSuccess) {
        completed = true;
        throw const ApiException(0, 'server_timeout');
      }
      throw const ApiException(503, 'face_match_unavailable');
    }
    completed = true;
    return {'id': sessionId, 'status': 'verified'};
  }
}

VerificationFlowScreen _verificationScreen(
  DemoApi api, {
  OnDeviceIdOcr? idOcr,
}) => VerificationFlowScreen(
  api: api,
  idOcr: idOcr ?? OnDeviceIdOcr(readText: (_) async => ''),
  pickPhoto: (source) async => VerificationImage(
    bytes: base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/6+8AAAAASUVORK5CYII=',
    ),
    mimeType: source == ImageSource.camera ? 'image/jpeg' : 'image/png',
  ),
);

class _PendingResponderApi extends DemoApi {
  _PendingResponderApi({this.verificationStatus = 'not_started'})
    : super(identity: const _FakeIdentity());

  final String verificationStatus;

  @override
  Future<ResponderMe> responderMe() async =>
      const ResponderMe(status: 'approved', displayName: 'Riya');

  @override
  Future<Map<String, dynamic>> verificationMe() async => {
    'status': verificationStatus,
    'session_id': null,
  };
}
