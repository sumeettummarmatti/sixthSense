import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sixthsense_app/core/api/device_identity.dart';
import 'package:sixthsense_app/features/onboarding/onboarding_flow.dart';

void main() {
  testWidgets('sign-in asks for email (free), not a phone number', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: OnboardingFlow(api: _FakeOnboardingApi())),
    );

    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Phone number'), findsNothing);

    await tester.enterText(find.byType(TextField), 'not-an-email');
    await tester.tap(find.text('Continue'));
    await tester.pump();
    expect(
      find.text('Enter a valid email address to continue.'),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField), 'tanisha@college.edu.in');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Enter the verification code we emailed to tanisha@college.edu.in.',
      ),
      findsOneWidget,
    );
  });
}

class _FakeOnboardingApi extends DemoApi {
  _FakeOnboardingApi();

  @override
  Future<void> requestOtp(String email) async {}
}
