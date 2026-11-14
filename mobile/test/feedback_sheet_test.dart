import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sixthsense_app/core/api/device_identity.dart';
import 'package:sixthsense_app/core/theme/app_theme.dart';
import 'package:sixthsense_app/features/feedback/feedback_sheet.dart';

class _FakeFeedbackApi extends DemoApi {
  final sent = <FeedbackDraft>[];

  @override
  Future<void> sendFeedback(FeedbackDraft draft) async => sent.add(draft);
}

Future<void> _openSheet(
  WidgetTester tester,
  DemoApi api, {
  String? walkId,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showFeedbackSheet(
              context,
              api: api,
              journeyId: 'j1',
              walkId: walkId,
              companionName: walkId == null ? null : 'Riya',
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// A tall phone screen so long forms and sheets fit without scrolling.
void _tallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('journey feedback: route stars, chips and a note', (
    tester,
  ) async {
    _tallScreen(tester);
    final api = _FakeFeedbackApi();
    await _openSheet(tester, api);
    expect(find.text('How was it?'), findsOneWidget);
    expect(find.byKey(const ValueKey('companion-star-1')), findsNothing);
    expect(
      find.byKey(const ValueKey('feedback-chip-companion_was_late')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('feedback-send')));
    await tester.pump();
    expect(find.text('Pick the stars, or tap Skip.'), findsOneWidget);
    expect(api.sent, isEmpty);

    await tester.tap(find.byKey(const ValueKey('route-star-4')));
    await tester.tap(find.byKey(const ValueKey('feedback-chip-well_lit')));
    await tester.tap(
      find.byKey(const ValueKey('feedback-chip-would_walk_again')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('feedback-note')),
      'Busy road, plenty of shops open',
    );
    await tester.tap(find.byKey(const ValueKey('feedback-send')));
    await tester.pumpAndSettle();

    final draft = api.sent.single;
    expect(draft.toJson(), {
      'journey_id': 'j1',
      'route_stars': 4,
      'chips': ['well_lit', 'would_walk_again'],
      'note': 'Busy road, plenty of shops open',
    });
    expect(find.text('How was it?'), findsNothing);
  });

  testWidgets('walk feedback asks for companion stars too', (tester) async {
    _tallScreen(tester);
    final api = _FakeFeedbackApi();
    await _openSheet(tester, api, walkId: 'w1');
    expect(find.text('Walking with Riya'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('route-star-3')));
    await tester.tap(find.byKey(const ValueKey('feedback-send')));
    await tester.pump();
    expect(api.sent, isEmpty); // companion stars missing
    await tester.tap(find.byKey(const ValueKey('companion-star-5')));
    await tester.tap(
      find.byKey(const ValueKey('feedback-chip-companion_was_late')),
    );
    await tester.tap(find.byKey(const ValueKey('feedback-send')));
    await tester.pumpAndSettle();
    expect(api.sent.single.toJson(), {
      'journey_id': 'j1',
      'walk_id': 'w1',
      'route_stars': 3,
      'companion_stars': 5,
      'chips': ['companion_was_late'],
      'note': '',
    });
  });

  testWidgets('feedback can be skipped and the note is capped at 500', (
    tester,
  ) async {
    _tallScreen(tester);
    final api = _FakeFeedbackApi();
    await _openSheet(tester, api);
    await tester.enterText(
      find.byKey(const ValueKey('feedback-note')),
      'n' * 600,
    );
    final note = tester.widget<TextField>(
      find.byKey(const ValueKey('feedback-note')),
    );
    expect(note.controller!.text.length, 500);
    await tester.tap(find.byKey(const ValueKey('feedback-skip')));
    await tester.pumpAndSettle();
    expect(find.text('How was it?'), findsNothing);
    expect(api.sent, isEmpty);
  });
}
