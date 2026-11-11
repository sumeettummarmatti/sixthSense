import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sixthsense_app/core/api/device_identity.dart';
import 'package:sixthsense_app/features/contacts/contact_alerts_screen.dart';

class _FakeApi extends DemoApi {
  _FakeApi(this.alerts);

  List<ContactAlert> alerts;
  final calls = <String>[];

  @override
  Future<List<ContactAlert>> activeAlerts() async => alerts;

  @override
  Future<void> acknowledgeAlert(String id) async => calls.add('ack:$id');

  @override
  Future<void> resolveAlert(String id) async {
    calls.add('resolve:$id');
    alerts = [];
  }

  @override
  Future<void> raiseAlarm(String id) async => calls.add('raise:$id');
}

ContactAlert _alert({
  bool full = false,
  bool covert = false,
  bool ack = false,
}) => ContactAlert.fromJson({
  'id': 'e1',
  'owner_label': 'priya',
  'level': full ? 'full_escalation' : 'contact_alert',
  'covert': covert,
  'opened_at': '2026-11-12T10:00:00Z',
  'acknowledged': ack,
  'verification_code': '3VYM-5UV5',
});

Future<void> _open(WidgetTester tester, DemoApi api) async {
  await tester.pumpWidget(MaterialApp(home: ContactAlertsScreen(api: api)));
  await tester.pump();
}

void main() {
  testWidgets('missed check-in shows code and all three actions', (
    tester,
  ) async {
    final api = _FakeApi([_alert()]);
    await _open(tester, api);

    expect(find.text('priya missed a check-in'), findsOneWidget);
    expect(find.text('3VYM-5UV5'), findsOneWidget);
    expect(find.textContaining("don't call"), findsNothing);

    await tester.tap(find.text("I'm on it"));
    await tester.pump();
    await tester.tap(find.text("I can't reach them, raise the alarm"));
    await tester.pump();
    expect(api.calls, ['ack:e1', 'raise:e1']);

    await tester.tap(find.text("I've reached them, they're OK"));
    await tester.pump();
    await tester.pump();
    expect(api.calls.last, 'resolve:e1');
    expect(find.text('No open alerts'), findsOneWidget);
  });

  testWidgets('silent SOS warns not to call and has no raise button', (
    tester,
  ) async {
    await _open(
      tester,
      _FakeApi([_alert(full: true, covert: true, ack: true)]),
    );

    expect(find.text('priya needs help now'), findsOneWidget);
    expect(
      find.textContaining("Silent alarm: don't call them"),
      findsOneWidget,
    );
    expect(find.text('Someone is on it.'), findsOneWidget);
    expect(find.text("I'm on it"), findsNothing);
    expect(find.text("I can't reach them, raise the alarm"), findsNothing);
  });

  testWidgets('home banner appears only when there is an open alert', (
    tester,
  ) async {
    final api = _FakeApi([]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ContactAlertBanner(api: api)),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('contact-alert-banner')), findsNothing);

    api.alerts = [_alert(full: true)];
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(find.text('priya needs help now'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('contact-alert-banner')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('People you support'), findsOneWidget);
  });
}
