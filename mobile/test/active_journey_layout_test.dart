import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sixthsense_app/core/api/device_identity.dart';
import 'package:sixthsense_app/features/journey/journey_flow.dart';

void main() {
  testWidgets('a tall helpers panel during an alert scrolls, never overflows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 1920); // small phone
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: ActiveJourneyScreen(
          plan: const JourneyPlan(
            destination: 'Elita Promenade Phase 1, RBI Layout',
            checkInInterval: Duration(minutes: 5),
            realPin: '1111',
            duressPin: '2222',
          ),
          remaining: const Duration(minutes: 4),
          isCheckInDue: true,
          onCheckIn: () {},
          onEnd: () {},
          onSos: (_) {},
          onRequestBatteryExemption: () {},
          helpersPanel: const SizedBox(
            key: ValueKey('tall-panel'),
            height: 520,
          ),
          compact: ValueNotifier(
            const HelpView(fullAlert: true, anyAlert: true, helpers: []),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('tall-panel')), findsOneWidget);
    await tester.scrollUntilVisible(find.text('End journey').last, 200);
    expect(find.text('SOS'), findsOneWidget);
  });
}
