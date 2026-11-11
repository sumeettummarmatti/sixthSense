import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sixthsense_app/core/api/device_identity.dart';
import 'package:sixthsense_app/features/contacts/contact_alerts.dart';

class _FakeApi extends DemoApi {
  _FakeApi();

  final accepted = <String>[];

  @override
  Future<String> acceptInvite(String linkOrToken) async {
    accepted.add(DemoApi.inviteTokenFrom(linkOrToken));
    return 'Priya';
  }
}

void main() {
  test('invite token is the part after #, or the bare token', () {
    expect(
      DemoApi.inviteTokenFrom(' https://sixthsense.app/invite#abc_123-XYZ '),
      'abc_123-XYZ',
    );
    expect(DemoApi.inviteTokenFrom('abc_123'), 'abc_123');
    expect(DemoApi.inviteTokenFrom('https://sixthsense.app/invite#'), '');
    expect(DemoApi.inviteTokenFrom('   '), '');
  });

  testWidgets('pasting an invite link accepts it and offers Telegram', (
    tester,
  ) async {
    final api = _FakeApi();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => acceptInviteFlow(context, api),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Accept'));
    await tester.pump();
    expect(find.text('Paste the invite link you were sent.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('invite-link')),
      'https://sixthsense.app/invite#tok123',
    );
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();

    expect(api.accepted, ['tok123']);
    expect(find.text('You are now a trusted contact'), findsOneWidget);
    expect(find.textContaining('Priya asks for help'), findsOneWidget);
    expect(find.text('Get alerts on Telegram'), findsOneWidget);
  });
}
