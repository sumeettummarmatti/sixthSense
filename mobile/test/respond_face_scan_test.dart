import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sixthsense_app/core/api/device_identity.dart';
import 'package:sixthsense_app/core/theme/app_theme.dart';
import 'package:sixthsense_app/features/face_scan/face_scan_screen.dart';
import 'package:sixthsense_app/features/respond/respond_screen.dart';

class _MemoryIdentity extends DeviceIdentity {
  const _MemoryIdentity();

  @override
  Future<void> saveValue(String name, String? value) async {}

  @override
  Future<String?> readValue(String name) async => null;
}

/// Lets frames run without waiting to settle: the offer card's live map keeps
/// animating (pulsing SOS ring), so pumpAndSettle would never return.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// A verified responder with one open request nearby.
class _ResponderApi extends DemoApi {
  _ResponderApi() : super(identity: const _MemoryIdentity());

  final calls = <String>[];
  ApiException? goingError;

  @override
  Future<ResponderMe> responderMe() async =>
      const ResponderMe(status: 'approved', displayName: 'Riya');

  @override
  Future<Map<String, dynamic>> verificationMe() async => {
    'status': 'verified',
    'session_id': null,
  };

  @override
  Future<List<ResponderOffer>> responderOffers() async => [
    ResponderOffer.fromJson({
      'id': 'o1',
      'status': 'offered',
      'distance_m': 300,
      'walk_minutes': 4,
      'opened_at': DateTime.now().toUtc().toIso8601String(),
      'rough_area': {'latitude': 12.89, 'longitude': 77.58},
    }),
  ];

  @override
  Future<OwnerKeys> goingToHelp(
    String offerId, {
    VerificationImage? scan,
  }) async {
    calls.add('going:$offerId:${scan == null ? 'no-scan' : 'scan'}');
    final error = goingError;
    if (error != null) {
      goingError = null;
      throw error;
    }
    return OwnerKeys.fromJson({'journey_id': 'j1', 'keys': <Object>[]});
  }
}

FaceScanCamera _camera(int faces) =>
    () async => FaceScanCapture(
      image: VerificationImage(
        bytes: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]),
        mimeType: 'image/jpeg',
      ),
      faces: faces,
    );

Future<void> _open(WidgetTester tester, _ResponderApi api, int faces) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: RespondScreen(
        api: api,
        pollInterval: const Duration(hours: 1),
        faceScanCamera: _camera(faces),
      ),
    ),
  );
  await _frames(tester);
}

Future<void> _tapGoing(WidgetTester tester) async {
  final going = find.byKey(const ValueKey('offer-going'));
  await tester.ensureVisible(going);
  await tester.tap(going);
  await _frames(tester);
}

void main() {
  testWidgets('"I\'m going" sends a face scan with the request', (
    tester,
  ) async {
    final api = _ResponderApi();
    await _open(tester, api, 1);
    await _tapGoing(tester);
    expect(find.text("Confirm it's you"), findsOneWidget);
    expect(api.calls, isEmpty);

    await tester.tap(find.byKey(const ValueKey('face-scan-start')));
    await _frames(tester);
    expect(api.calls, ['going:o1:scan']);
    expect(find.text("Confirm it's you"), findsNothing);
  });

  testWidgets('two faces in the photo: nothing is sent', (tester) async {
    final api = _ResponderApi();
    await _open(tester, api, 2);
    await _tapGoing(tester);
    await tester.tap(find.byKey(const ValueKey('face-scan-start')));
    await _frames(tester);
    expect(
      find.textContaining('Only you should be in the photo'),
      findsOneWidget,
    );
    expect(api.calls, isEmpty);
  });

  testWidgets('a face mismatch keeps the scan open', (tester) async {
    final api = _ResponderApi()
      ..goingError = const ApiException(403, 'face_mismatch');
    await _open(tester, api, 1);
    await _tapGoing(tester);
    await tester.tap(find.byKey(const ValueKey('face-scan-start')));
    await _frames(tester);
    expect(find.textContaining('did not match'), findsOneWidget);
    expect(find.text("Confirm it's you"), findsOneWidget);
  });
}
