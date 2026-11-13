import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api/device_identity.dart';
import '../../core/location/live_location.dart';
import '../../core/sos/live_audio.dart';
import '../contacts/contact_alerts_screen.dart';
import '../contacts/my_people_screen.dart';
import '../journey/journey_flow.dart';
import '../respond/respond_screen.dart';

/// Signed-in home: my journey, my people, the people I support, and nearby
/// requests if I'm a verified responder.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.api,
    this.relay,
    this.pollInterval = const Duration(seconds: 10),
  });

  final DemoApi api;

  /// Live location relay; defaults to the app-wide one.
  final LiveLocationRelay? relay;
  final Duration pollInterval;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  var _tab = 0;
  var _openAlerts = 0;
  var _openOffers = 0;
  Timer? _poll;

  LiveLocationRelay get _relay => widget.relay ?? LiveLocationRelay.instance;

  @override
  void initState() {
    super.initState();
    // Listen for live locations of people I support (decrypted on this phone).
    unawaited(_relay.start(widget.api));
    // Live audio of people I support, only for sessions I choose to hear.
    LiveAudioPlayer.instance.start(_relay);
    _checkAlerts();
    _poll = Timer.periodic(widget.pollInterval, (_) => _checkAlerts());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _checkOffers() async {
    try {
      final offers = await widget.api.responderOffers();
      if (!mounted) return;
      final waiting = offers.where((offer) => !offer.going).toList();
      final grew = waiting.length > _openOffers;
      setState(() => _openOffers = waiting.length);
      if (grew && _tab != 3) {
        final offer = waiting.last;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              duration: const Duration(seconds: 12),
              content: Text(
                'Someone ~${offer.distanceMeters} m away needs help (~${offer.walkMinutes} min walk)',
              ),
              action: SnackBarAction(
                label: 'Open',
                onPressed: () => setState(() => _tab = 3),
              ),
            ),
          );
      }
    } catch (_) {
      // Not a responder, or offline.
    }
  }

  Future<void> _checkAlerts() async {
    unawaited(_checkOffers());
    try {
      final alerts = await widget.api.activeAlerts();
      if (!mounted) return;
      final grew = alerts.length > _openAlerts;
      setState(() => _openAlerts = alerts.length);
      if (grew && _tab != 2) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                '${alerts.last.ownerLabel} ${alerts.last.fullEscalation ? 'needs help now' : 'missed a check-in'}',
              ),
              action: SnackBarAction(
                label: 'Open',
                onPressed: () => setState(() => _tab = 2),
              ),
            ),
          );
      }
    } catch (_) {
      // Offline: the journey tab keeps working on the phone alone.
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          JourneyFlow(api: widget.api, relay: _relay),
          MyPeopleScreen(api: widget.api),
          ContactAlertsScreen(api: widget.api, relay: _relay),
          RespondScreen(api: widget.api, relay: _relay),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (tab) => setState(() => _tab = tab),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.route_outlined),
            selectedIcon: Icon(Icons.route_rounded),
            label: 'Journey',
          ),
          const NavigationDestination(
            icon: Icon(Icons.diversity_1_outlined),
            selectedIcon: Icon(Icons.diversity_1_rounded),
            label: 'My people',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: _openAlerts > 0,
              backgroundColor: colors.error,
              label: Text('$_openAlerts'),
              child: const Icon(Icons.volunteer_activism_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: _openAlerts > 0,
              backgroundColor: colors.error,
              label: Text('$_openAlerts'),
              child: const Icon(Icons.volunteer_activism_rounded),
            ),
            label: 'I support',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: _openOffers > 0,
              backgroundColor: colors.error,
              label: Text('$_openOffers'),
              child: const Icon(Icons.health_and_safety_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: _openOffers > 0,
              backgroundColor: colors.error,
              label: Text('$_openOffers'),
              child: const Icon(Icons.health_and_safety_rounded),
            ),
            label: 'Respond',
          ),
        ],
      ),
    );
  }
}
