import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sixthsense_app/core/api/device_identity.dart';
import 'package:sixthsense_app/core/theme/app_theme.dart';
import 'package:sixthsense_app/features/contacts/people_screen.dart';
import 'package:sixthsense_app/features/feedback/feedback_sheet.dart';
import 'package:sixthsense_app/features/journey/journey_flow.dart';

class _RatingApi extends DemoApi {
  final rated = <String, int>{};

  @override
  Future<void> rateResponder({
    required String offerId,
    required int stars,
    String note = '',
  }) async => rated[offerId] = stars;
}

class _PeopleApi extends DemoApi {
  @override
  Future<List<Map<String, dynamic>>> listContacts() async => const [];

  @override
  Future<List<ContactAlert>> activeAlerts() async => const [];
}

void _tallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
}

void main() {
  test('a running journey plan survives a restart (route is not kept)', () {
    const plan = JourneyPlan(
      destination: 'Library',
      checkInInterval: Duration(minutes: 20),
      realPin: '1234',
      duressPin: '9999',
      smsNumbers: ['+911234567890'],
      smsFallbackEnabled: true,
      destinationLatitude: 12.9,
      destinationLongitude: 77.6,
      listenForWords: true,
      recordAudio: false,
    );
    final back = JourneyPlan.fromJson(plan.toJson());
    expect(back.destination, 'Library');
    expect(back.checkInInterval, const Duration(minutes: 20));
    expect((back.realPin, back.duressPin), ('1234', '9999'));
    expect(back.smsNumbers, ['+911234567890']);
    expect(back.smsFallbackEnabled, isTrue);
    expect((back.destinationLatitude, back.destinationLongitude), (12.9, 77.6));
    expect((back.listenForWords, back.recordAudio), (true, false));
    expect(back.route, isNull);
    expect(plan.toJson().containsKey('route'), isFalse);
  });

  testWidgets('responders are rated one by one; one star warns first', (
    tester,
  ) async {
    _tallScreen(tester);
    final api = _RatingApi();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showResponderRatingSheet(
                context,
                api: api,
                responders: const [
                  ResponderToRate(offerId: 'o1', name: 'Riya'),
                  ResponderToRate(offerId: 'o2', name: 'Meera'),
                ],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Riya'), findsOneWidget);
    expect(find.text('Meera'), findsOneWidget);
    expect(find.byKey(const ValueKey('responder-one-star-warning')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('responder-star-o1-1')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('responder-one-star-warning')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('responder-star-o2-5')));
    await tester.tap(find.byKey(const ValueKey('responder-send')));
    await tester.pumpAndSettle();
    expect(api.rated, {'o1': 1, 'o2': 5});
  });

  testWidgets('People tab holds My people and I support', (tester) async {
    _tallScreen(tester);
    final tab = ValueNotifier<int>(0);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: PeopleScreen(api: _PeopleApi(), tab: tab),
      ),
    );
    await tester.pump();
    expect(find.text('People'), findsOneWidget);
    expect(find.byKey(const ValueKey('people-tab-mine')), findsOneWidget);
    expect(find.byKey(const ValueKey('people-tab-support')), findsOneWidget);
    // An incoming alert switches to "I support".
    tab.value = 1;
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('People you support'), findsNothing); // no nested app bar
    expect(tab.value, 1);
    await tester.tap(find.byKey(const ValueKey('people-tab-mine')));
    await tester.pump(const Duration(seconds: 1));
    expect(tab.value, 0);
    await tester.pumpWidget(const SizedBox()); // stop the alert polling
  });
}
