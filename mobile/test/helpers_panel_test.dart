import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sixthsense_app/core/api/device_identity.dart';
import 'package:sixthsense_app/core/contacts/contact_book.dart';
import 'package:sixthsense_app/core/location/live_location.dart';
import 'package:sixthsense_app/features/help/helpers_panel.dart';

Helper _helper({
  required String id,
  bool responder = false,
  String? label,
  String? link,
  String keyId = 'k1',
  bool arrived = false,
}) => Helper(
  id: id,
  isResponder: responder,
  label: label,
  contactLinkId: link,
  arrived: arrived,
  acceptedAt: DateTime(2026, 11, 13, 16),
  keys: [PeerKey(keyId: keyId, x25519PublicKey: '', ed25519PublicKey: '')],
);

Position _at(double lat, double lng) => Position(
  latitude: lat,
  longitude: lng,
  timestamp: DateTime(2026, 11, 13, 16),
  accuracy: 5,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

void main() {
  final relay = LiveLocationRelay.instance;

  tearDown(() {
    relay.helperLocations.value = {};
    relay.myPosition.value = null;
  });

  Future<void> pump(WidgetTester tester, HelpView view) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: HelpersPanel(
          help: ValueNotifier(view),
          relay: relay,
          names: const {'link-1': LocalContact(name: 'Shruj')},
        ),
      ),
    ),
  );

  test('search line shows radius and counts until two are coming', () {
    const searching = HelpView(
      fullAlert: true,
      anyAlert: true,
      helpers: [],
      search: ResponderSearch(
        radiusMeters: 500,
        onDutyNearby: 3,
        asked: 2,
        going: 1,
      ),
    );
    expect(
      searchLine(searching),
      'Searching 500 m · 3 responders on duty nearby · 2 asked · 1 coming',
    );
    expect(searchLine(HelpView.none), isNull);
  });

  testWidgets('nothing shows before an alert', (tester) async {
    await pump(tester, HelpView.none);
    expect(find.byKey(const ValueKey('helpers-panel')), findsNothing);
  });

  testWidgets('waiting text while nobody has said they are coming', (
    tester,
  ) async {
    await pump(
      tester,
      const HelpView(fullAlert: true, anyAlert: true, helpers: []),
    );
    expect(
      find.textContaining('Asking your contacts and responders'),
      findsOneWidget,
    );
  });

  testWidgets('a contact and a responder coming, with distance', (
    tester,
  ) async {
    relay.myPosition.value = _at(12.8905, 77.5826);
    relay.helperLocations.value = {
      'k1': ReceivedLocation(
        sessionId: 'j',
        latitude: 12.8932, // ~300 m north
        longitude: 77.5826,
        accuracyMeters: 5,
        takenAt: DateTime(2026, 11, 13, 16),
        sequence: 1,
      ),
    };
    await pump(
      tester,
      HelpView(
        fullAlert: true,
        anyAlert: true,
        helpers: [
          _helper(id: 'a', link: 'link-1'),
          _helper(
            id: 'b',
            responder: true,
            label: 'Riya',
            keyId: 'k2',
            arrived: true,
          ),
        ],
      ),
    );
    expect(find.text('2 people are coming'), findsOneWidget);
    expect(find.text('Shruj'), findsOneWidget);
    expect(
      find.textContaining(RegExp(r'^300 m · ~[56] min walk$')),
      findsOneWidget,
    );
    expect(find.text('Riya · verified responder'), findsOneWidget);
    expect(find.text('Says they have reached you'), findsOneWidget);
  });
}
