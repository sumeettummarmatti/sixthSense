import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sixthsense_app/core/api/device_identity.dart';
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
  Future<CompanionMe> verifyAsCompanion() async {
    calls.add('verify');
    return me = CompanionMe(
      status: 'pending',
      verifiedMethod: 'mock',
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
  Future<WalkView> acceptWalk(String walkId) async {
    calls.add('accept:$walkId');
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

Future<void> _open(
  WidgetTester tester,
  _FakeWalkApi api, {
  String? journeyId = 'j1',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: WalkFlow(
        api: api,
        journeyId: journeyId,
        locate: () async => (12.9719, 77.6412),
        pollInterval: const Duration(milliseconds: 100),
        verificationDelay: const Duration(milliseconds: 50),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

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

  testWidgets('companion demo verification passes and waits for approval', (
    tester,
  ) async {
    _tallScreen(tester);
    final api = _FakeWalkApi();
    await _open(tester, api);
    await tester.tap(find.byKey(const ValueKey('walk-companion-role')));
    await tester.pumpAndSettle();
    expect(find.text('Demo verification'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('walk-demo-verify')));
    await tester.pump();
    expect(find.text('Checking (demo)…'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(api.calls, ['verify']);
    expect(find.text('Waiting for approval'), findsOneWidget);
    expect(find.textContaining('14/11/2026'), findsOneWidget);
  });

  testWidgets('companion needs a willing profile first', (tester) async {
    _tallScreen(tester);
    await _open(tester, _FakeWalkApi(willing: false));
    await tester.tap(find.byKey(const ValueKey('walk-companion-role')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('walk-open-profile')), findsOneWidget);
    expect(find.byKey(const ValueKey('walk-demo-verify')), findsNothing);
  });

  testWidgets('approved companion goes available, sees and accepts a request', (
    tester,
  ) async {
    _tallScreen(tester);
    final api = _FakeWalkApi(
      me: const CompanionMe(status: 'approved', verifiedMethod: 'mock'),
    );
    await _open(tester, api);
    await tester.tap(find.byKey(const ValueKey('walk-companion-role')));
    await tester.pumpAndSettle();
    expect(find.text('Approved · demo verification'), findsOneWidget);

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
    expect(api.calls, contains('accept:w1'));
    expect(find.text('Walking with Priya'), findsOneWidget);
    expect(find.text('0427'), findsOneWidget);
    // Unmount so the poll timers stop.
    await tester.pumpWidget(const SizedBox());
  });
}
