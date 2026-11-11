import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sixthsense_app/features/journey/journey_flow.dart';
import 'package:sixthsense_app/main.dart';

void main() {
  testWidgets('home shows brand and tagline', (tester) async {
    await tester.pumpWidget(const SixthSenseApp());
    expect(find.text('SixthSense'), findsOneWidget);
    expect(find.text('See the risk. Stop it early.'), findsOneWidget);
  });

  testWidgets('journey timer, real/duress PINs, and SOS flows work', (
    tester,
  ) async {
    var duressRequests = 0;
    var covertSosRequests = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: JourneyFlow(
          now: () => tester.binding.clock.now(),
          onDuressRequested: () => duressRequests++,
          onCovertSosRequested: () => covertSosRequests++,
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('journey-destination')),
      'Library',
    );
    await tester.tap(find.text('1 min'));
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('journey-real-pin')),
      '1234',
    );
    await tester.enterText(
      find.byKey(const ValueKey('journey-duress-pin')),
      '5678',
    );
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start journey'));
    await tester.pumpAndSettle();

    expect(find.text('until your next check-in'), findsOneWidget);
    await tester.pump(const Duration(minutes: 1));
    expect(find.text('Your check-in is due'), findsOneWidget);

    for (var attempt = 0; attempt < 3; attempt++) {
      await tester.tap(find.text('Check in'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('journey-check-in-pin')),
        '9999',
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
    }
    expect(duressRequests, 1);

    await tester.tap(find.text('Check in'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('journey-check-in-pin')),
      '5678',
    );
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(duressRequests, 2);
    await tester.pump();
    expect(find.text('01:00'), findsOneWidget);
    expect(find.text('until your next check-in'), findsOneWidget);

    await tester.tap(find.text('Check in'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('journey-check-in-pin')),
      '1234',
    );
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(duressRequests, 2);

    await tester.tap(find.text('SOS'));
    await tester.pumpAndSettle();
    expect(find.text('SOS requested'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.longPress(find.byIcon(Icons.wb_twilight_rounded));
    await tester.pump();
    expect(covertSosRequests, 1);
    expect(find.text('SOS requested'), findsNothing);
  });
}
