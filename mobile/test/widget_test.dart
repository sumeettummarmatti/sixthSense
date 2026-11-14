import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sixthsense_app/core/api/device_identity.dart';
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
    final runtimeCalls = <MethodCall>[];
    const runtimeChannel = MethodChannel('in.sixthsense/journey_runtime');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(runtimeChannel, (call) async {
      runtimeCalls.add(call);
      return null;
    });
    const sosChannel = MethodChannel('in.sixthsense/sudden_sos');
    messenger.setMockMethodCallHandler(sosChannel, (call) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(runtimeChannel, null);
      messenger.setMockMethodCallHandler(sosChannel, null);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: JourneyFlow(
          now: () => tester.binding.clock.now(),
          api: _FakeJourneyApi(() => tester.binding.clock.now()),
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
    await tester.scrollUntilVisible(
      find.text('Start journey'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
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

    await tester.tap(find.byTooltip('End journey'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('End journey').last);
    await tester.pumpAndSettle();
    expect(runtimeCalls.map((call) => call.method), [
      'startJourney',
      'requestDuress',
      'requestDuress',
      'checkIn',
      'checkIn',
      'requestSos',
      'requestCovertSos',
      'endJourney',
    ]);
    final startArguments = runtimeCalls.first.arguments as Map;
    expect(startArguments['smsNumbers'], isEmpty);
    expect(startArguments['smsFallbackEnabled'], isFalse);
    expect(
      (runtimeCalls.first.arguments as Map).containsKey('destination'),
      isFalse,
    );
  });
}

class _FakeJourneyApi extends DemoApi {
  _FakeJourneyApi(this.now);

  final DateTime Function() now;
  Duration interval = const Duration(minutes: 1);

  @override
  Future<JourneySnapshot> startJourney(int checkInIntervalMinutes) async {
    interval = Duration(minutes: checkInIntervalMinutes);
    return JourneySnapshot(
      id: 'journey-1',
      state: 'active',
      nextCheckInAt: now().add(interval),
      heartbeatTimeoutMinutes: 10,
    );
  }

  @override
  Future<JourneySnapshot> checkIn(
    String journeyId, {
    required bool duress,
  }) async => JourneySnapshot(
    id: journeyId,
    state: duress ? 'full_escalation' : 'active',
    nextCheckInAt: now().add(interval),
    heartbeatTimeoutMinutes: 10,
  );

  @override
  Future<JourneySnapshot> promptShown(String journeyId) async =>
      JourneySnapshot(
        id: journeyId,
        state: 'private_prompt',
        nextCheckInAt: now().add(interval),
        heartbeatTimeoutMinutes: 10,
      );

  @override
  Future<JourneySnapshot> requestSos(
    String journeyId, {
    required bool covert,
  }) async => JourneySnapshot(
    id: journeyId,
    state: covert ? 'active' : 'full_escalation',
    nextCheckInAt: now().add(interval),
    heartbeatTimeoutMinutes: 10,
  );

  @override
  Future<JourneySnapshot> endJourney(String journeyId) async => JourneySnapshot(
    id: journeyId,
    state: 'resolved',
    nextCheckInAt: now().add(interval),
    heartbeatTimeoutMinutes: 10,
  );
}
