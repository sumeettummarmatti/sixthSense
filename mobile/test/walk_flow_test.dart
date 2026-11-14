import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sixthsense_app/core/api/device_identity.dart';

import 'dart:typed_data';

import 'package:sixthsense_app/core/theme/app_theme.dart';
import 'package:sixthsense_app/features/face_scan/face_scan_screen.dart';
import 'package:sixthsense_app/features/walk/walk_flow.dart';

const _riya = {
  'companion_id': 'c-riya',
  'profile': {
    'first_name': 'Riya',
    'bio': 'Walks this way after class',
    'strengths': ['first_aid_trained', 'speaks_kannada'],
    'languages': ['Kannada'],
  },
  'rating': 4.5,
  'rating_count': 2,
  'distance_m': 300,
  'walk_minutes': 4,
};

Map<String, Object?> _walkJson(
  String status, {
  String role = 'traveller',
  String? code,
  String? endReason,
}) => {
  'id': 'w1',
  'role': role,
  'status': status,
  'journey_id': role == 'traveller' ? 'j1' : null,
  'partner': {
    'first_name': role == 'traveller' ? 'Riya' : 'Priya',
    'bio': '',
    'strengths': <String>[],
    'languages': <String>[],
  },
  'handshake_code': code,
  'meet_near': status == 'accepted'
      ? {'latitude': 12.972, 'longitude': 77.641}
      : null,
  'partner_keys': <Object>[],
  'expires_at': DateTime.now()
      .add(const Duration(minutes: 9))
      .toUtc()
      .toIso8601String(),
  'end_reason': endReason,
};

class _FakeWalkApi extends DemoApi {
  _FakeWalkApi({
    this.me = const CompanionMe(status: 'none'),
    this.willing = true,
  });

  CompanionMe me;
  bool willing;
  final calls = <String>[];
  WalkView? next;

  /// What the server says to the next accept: null = passes.
  ApiException? acceptError;
  List<CompanionCard> cards = [
    CompanionCard.fromJson(_riya),
    CompanionCard.fromJson({
      ..._riya,
      'companion_id': 'c-arun',
      'profile': {..._riya['profile']! as Map, 'first_name': 'Arun'},
      'rating': null,
      'rating_count': 0,
    }),
  ];

  @override
  Future<WalkView?> currentWalk() async => null;

  @override
  Future<Profile?> profile() async =>
      Profile(firstName: 'Priya', willingCompanion: willing);

  @override
  Future<CompanionMe> companionMe() async => me;

  @override
  Future<CompanionMe> joinAsCompanion() async {
    calls.add('join');
    return me = CompanionMe(
      status: 'approved',
      identityVerified: me.identityVerified,
      verifiedMethod: 'identity',
      verifiedAt: DateTime(2026, 11, 14),
    );
  }

  @override
  Future<List<CompanionCard>> searchCompanions({
    required String journeyId,
    required double lat,
    required double lng,
    bool womenOnly = false,
  }) async {
    calls.add('search:$journeyId:women=$womenOnly');
    return womenOnly ? cards.take(1).toList() : cards;
  }

  @override
  Future<WalkView> askCompanion({
    required String journeyId,
    required String companionId,
    required double lat,
    required double lng,
  }) async {
    calls.add('ask:$companionId');
    return WalkView.fromJson(_walkJson('requested'));
  }

  @override
  Future<WalkView> walk(String walkId) async =>
      next ?? WalkView.fromJson(_walkJson('requested'));

  @override
  Future<List<WalkRequestView>> walkRequests() async => [
    WalkRequestView.fromJson({
      'id': 'w1',
      'traveller_first_name': 'Priya',
      'rough_area': {'latitude': 12.972, 'longitude': 77.641},
      'distance_m': 400,
      'expires_at': DateTime.now()
          .add(const Duration(minutes: 7))
          .toUtc()
          .toIso8601String(),
    }),
  ];

  @override
  Future<void> sendCompanionPresence(double lat, double lng) async =>
      calls.add('presence');

  @override
  Future<WalkView> acceptWalk(
    String walkId, {
    required VerificationImage scan,
  }) async {
    calls.add('accept:$walkId:${scan.mimeType}:${scan.bytes.length}');
    final error = acceptError;
    if (error != null) {
      acceptError = null;
      throw error;
    }
    return WalkView.fromJson(
      _walkJson('accepted', role: 'companion', code: '0427'),
    );
  }

  @override
  Future<WalkView> endWalk(String walkId) async {
    calls.add('end:$walkId');
    return WalkView.fromJson(_walkJson('ended', endReason: 'traveller'));
  }

  @override
  Future<void> sendFeedback(FeedbackDraft draft) async =>
      calls.add('feedback:${draft.walkId}:${draft.companionStars}');
}

/// A front-camera photo with [faces] faces found on the phone.
FaceScanCamera _camera(int faces) =>
    () async => FaceScanCapture(
      image: VerificationImage(
        bytes: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]),
        mimeType: 'image/jpeg',
      ),
      faces: faces,
    );

Future<void> _open(
  WidgetTester tester,
  _FakeWalkApi api, {
  String? journeyId = 'j1',
  int faces = 1,
  bool verifies = true,
  List<String>? verifications,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: WalkFlow(
        api: api,
        journeyId: journeyId,
        locate: () async => (12.9719, 77.6412),
        pollInterval: const Duration(milliseconds: 100),
        faceScanCamera: _camera(faces),
        verifyIdentity: (_) async {
          verifications?.add('opened');
          if (verifies) {
            api.me = const CompanionMe(status: 'none', identityVerified: true);
          }
          return verifies;
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _verifiedCompanion = CompanionMe(
  status: 'approved',
  identityVerified: true,
  verifiedMethod: 'identity',
);

/// A tall phone screen so long forms and sheets fit without scrolling.
void _tallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('traveller sees nearby companions and can filter women only', (
    tester,
  ) async {
    _tallScreen(tester);
    final api = _FakeWalkApi();
    await _open(tester, api);
    await tester.tap(find.byKey(const ValueKey('walk-traveller-role')));
    await tester.pumpAndSettle();

    expect(find.text('Riya'), findsOneWidget);
    expect(find.text('Arun'), findsOneWidget);
    expect(find.text('★ 4.5 (2)'), findsOneWidget);
    expect(find.text('New companion'), findsOneWidget);
    expect(find.text('~300 m away · 4 min walk'), findsNWidgets(2));
    expect(find.text('First-aid trained'), findsNWidgets(2));
    expect(find.textContaining('safe', findRichText: true), findsNothing);

    await tester.tap(find.byKey(const ValueKey('walk-women-only')));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'search:j1:women=true');
    expect(find.text('Arun'), findsNothing);
  });

  testWidgets('asking a companion waits, then shows the handshake code', (
    tester,
  ) async {
    _tallScreen(tester);
    final api = _FakeWalkApi();
    await _open(tester, api);
    await tester.tap(find.byKey(const ValueKey('walk-traveller-role')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('walk-ask-c-riya')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(api.calls, contains('ask:c-riya'));
    expect(find.text('Waiting for Riya'), findsOneWidget);

    api.next = WalkView.fromJson(_walkJson('accepted', code: '0427'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('walk-handshake-code')), findsOneWidget);
    expect(find.text('0427'), findsOneWidget);
    expect(find.text('Riya is walking with you'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('walk-end')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('End walk').last);
    await tester.pumpAndSettle();
    expect(api.calls, contains('end:w1'));
    // Walk feedback asks for the companion's stars too.
    expect(find.text('How was it?'), findsOneWidget);
    expect(find.text('Walking with Riya'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('route-star-4')));
    await tester.tap(find.byKey(const ValueKey('companion-star-5')));
    await tester.tap(find.byKey(const ValueKey('feedback-send')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('feedback:w1:5'));
  });

  testWidgets('without a journey the traveller cannot ask', (tester) async {
    _tallScreen(tester);
    await _open(tester, _FakeWalkApi(), journeyId: null);
    expect(
      find.text('Start a journey first to ask for a companion.'),
      findsOneWidget,
    );
    final button = tester.widget<ButtonStyleButton>(
      find.byKey(const ValueKey('walk-traveller-role')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('companion verifies identity once, then joins with no approval', (
    tester,
  ) async {
    _tallScreen(tester);
    final api = _FakeWalkApi();
    final verifications = <String>[];
    await _open(tester, api, verifications: verifications);
    await tester.tap(find.byKey(const ValueKey('walk-companion-role')));
    await tester.pumpAndSettle();
    expect(find.text('Verify your identity'), findsOneWidget);
    expect(find.text('Demo verification'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('walk-join')));
    await tester.pumpAndSettle();
    expect(verifications, ['opened']);
    expect(api.calls, ['join']);
    // Straight to available: no "Waiting for approval".
    expect(find.text('Waiting for approval'), findsNothing);
    expect(find.text('Verified companion'), findsOneWidget);
    expect(find.byKey(const ValueKey('walk-available')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('already verified people join without verifying again', (
    tester,
  ) async {
    _tallScreen(tester);
    final api = _FakeWalkApi(
      me: const CompanionMe(status: 'none', identityVerified: true),
    );
    final verifications = <String>[];
    await _open(tester, api, verifications: verifications);
    await tester.tap(find.byKey(const ValueKey('walk-companion-role')));
    await tester.pumpAndSettle();
    expect(find.text('Join as a companion'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('walk-join')));
    await tester.pumpAndSettle();
    expect(verifications, isEmpty);
    expect(api.calls, ['join']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('verification not finished: nothing is joined', (tester) async {
    _tallScreen(tester);
    final api = _FakeWalkApi();
    await _open(tester, api, verifies: false);
    await tester.tap(find.byKey(const ValueKey('walk-companion-role')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('walk-join')));
    await tester.pumpAndSettle();
    expect(api.calls, isEmpty);
    expect(find.text('Verify your identity'), findsOneWidget);
  });

  testWidgets('companion needs a willing profile first', (tester) async {
    _tallScreen(tester);
    await _open(tester, _FakeWalkApi(willing: false));
    await tester.tap(find.byKey(const ValueKey('walk-companion-role')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('walk-open-profile')), findsOneWidget);
    expect(find.byKey(const ValueKey('walk-join')), findsNothing);
  });

  testWidgets('companion accepts only after a face scan', (tester) async {
    _tallScreen(tester);
    final api = _FakeWalkApi(me: _verifiedCompanion);
    await _open(tester, api);
    await tester.tap(find.byKey(const ValueKey('walk-companion-role')));
    await tester.pumpAndSettle();
    expect(find.text('Verified companion'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('walk-available')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('presence'));

    expect(find.text('Priya asked to walk with you'), findsOneWidget);
    expect(find.textContaining('~400 m away'), findsOneWidget);
    api.next = WalkView.fromJson(
      _walkJson('accepted', role: 'companion', code: '0427'),
    );
    await tester.tap(find.byKey(const ValueKey('walk-accept-w1')));
    await tester.pumpAndSettle();
    // The scan comes first; nothing is accepted yet.
    expect(find.text("Confirm it's you"), findsOneWidget);
    expect(api.calls.where((c) => c.startsWith('accept')), isEmpty);

    await tester.tap(find.byKey(const ValueKey('face-scan-start')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('accept:w1:image/jpeg:7'));
    expect(find.text('Walking with Priya'), findsOneWidget);
    expect(find.text('0427'), findsOneWidget);
    // Unmount so the poll timers stop.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('no face or a face mismatch does not accept', (tester) async {
    _tallScreen(tester);
    final api = _FakeWalkApi(me: _verifiedCompanion);
    await _open(tester, api, faces: 0);
    await tester.tap(find.byKey(const ValueKey('walk-companion-role')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('walk-accept-w1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('face-scan-start')));
    await tester.pumpAndSettle();
    expect(find.textContaining('could not see a face'), findsOneWidget);
    expect(api.calls.where((c) => c.startsWith('accept')), isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Priya asked to walk with you'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('server face mismatch keeps the scan open to retry', (
    tester,
  ) async {
    _tallScreen(tester);
    final api = _FakeWalkApi(me: _verifiedCompanion)
      ..acceptError = const ApiException(403, 'face_mismatch')
      ..next = WalkView.fromJson(
        _walkJson('accepted', role: 'companion', code: '0427'),
      );
    await _open(tester, api);
    await tester.tap(find.byKey(const ValueKey('walk-companion-role')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('walk-accept-w1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('face-scan-start')));
    await tester.pumpAndSettle();
    expect(find.textContaining('did not match'), findsOneWidget);
    expect(find.text('Walking with Priya'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('face-scan-start')));
    await tester.pumpAndSettle();
    expect(find.text('Walking with Priya'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
