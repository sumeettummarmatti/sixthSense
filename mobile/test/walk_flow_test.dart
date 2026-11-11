import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sixthsense_app/features/walk/walk_flow.dart';

void main() {
  testWidgets('traveller can preview a walk and masked local chat', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: WalkFlow()));
    await tester.tap(find.byKey(const ValueKey('walk-traveller-role')));
    await tester.pumpAndSettle();
    expect(find.text('Request a walk'), findsOneWidget);

    await tester.tap(find.text('Preview sample match'));
    await tester.pumpAndSettle();
    expect(find.text('Sample companion'), findsOneWidget);
    expect(find.text('Sample profile · not verified'), findsOneWidget);
    await tester.tap(find.text('Continue to demo handshake'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('walk-handshake-code')), findsOneWidget);
    await tester.tap(find.text('Continue demo'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('walk-chat-input')),
      '+91 98765 43210',
    );
    await tester.tap(find.byKey(const ValueKey('walk-chat-send')));
    await tester.pump();
    expect(
      find.text('Phone numbers cannot be shared in masked chat.'),
      findsOneWidget,
    );
    expect(find.text('No messages yet'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('walk-chat-input')),
      'Meet at the library entrance',
    );
    await tester.tap(find.byKey(const ValueKey('walk-chat-send')));
    await tester.pump();
    expect(find.text('Meet at the library entrance'), findsOneWidget);

    await tester.tap(find.text('End walk demo'));
    await tester.pumpAndSettle();
    expect(find.text('Walk demo complete'), findsOneWidget);
    expect(find.text('Sample companion'), findsNothing);
  });

  testWidgets(
    'companion flow captures a selfie but labels liveness unverified',
    (tester) async {
      final pixel = Uint8List.fromList(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL9WQAAAABJRU5ErkJggg==',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(home: WalkFlow(captureSelfie: () async => pixel)),
      );
      await tester.tap(find.byKey(const ValueKey('walk-companion-role')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('walk-on-duty')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review sample walk request'));
      await tester.pumpAndSettle();
      expect(find.textContaining('not a liveness check'), findsOneWidget);

      await tester.tap(find.text('Take verification selfie'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('walk-selfie-preview')), findsOneWidget);
      await tester.ensureVisible(find.text('Continue demo only'));
      await tester.tap(find.text('Continue demo only'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('walk-handshake-code')), findsOneWidget);
    },
  );
}
