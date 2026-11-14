import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api/device_identity.dart';
import '../../core/location/live_location.dart';
import '../../core/sos/live_audio.dart';
import '../contacts/people_screen.dart';
import '../journey/journey_flow.dart';
import '../profile/profile_screen.dart';
import '../respond/respond_screen.dart';
import '../walk/walk_flow.dart';

/// Signed-in home: my journey, Walk With Me, people (mine and the ones I
/// support), nearby requests if I'm a verified responder, and my profile.
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
  // Tabs: 0 Journey, 1 Walk With Me, 2 People, 3 Respond, 4 Profile.
  static const _journeyTab = 0, _peopleTab = 2, _respondTab = 3;
  var _tab = _journeyTab;
  final _peopleSubTab = ValueNotifier<int>(0);
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
    _peopleSubTab.dispose();
    super.dispose();
  }

  Future<void> _checkOffers() async {
    try {
      final offers = await widget.api.responderOffers();
      if (!mounted) return;
      final waiting = offers.where((offer) => !offer.going).toList();
      final grew = waiting.length > _openOffers;
      setState(() => _openOffers = waiting.length);
      if (grew && _tab != _respondTab) {
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
                onPressed: () => setState(() => _tab = _respondTab),
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
      if (grew && (_tab != _peopleTab || _peopleSubTab.value != 1)) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                '${alerts.last.ownerLabel} ${alerts.last.fullEscalation ? 'needs help now' : 'missed a check-in'}',
              ),
              action: SnackBarAction(
                label: 'Open',
                onPressed: () {
                  _peopleSubTab.value = 1;
                  setState(() => _tab = _peopleTab);
                },
              ),
            ),
          );
      }
    } catch (_) {
      // Offline: the journey tab keeps working on the phone alone.
    }
  }

  /// Back never closes the app (that used to drop a running journey from the
  /// screen): other tabs go back to Journey, Journey sends the app to the background.
  void _onBack() {
    if (_tab != _journeyTab) {
      setState(() => _tab = _journeyTab);
      return;
    }
    unawaited(widget.api.identity.moveToBack());
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        body: IndexedStack(
          index: _tab,
          children: [
            JourneyFlow(api: widget.api, relay: _relay),
            // Built only while open, like the old pushed screen: it turns on
            // screenshot protection and resumes an ongoing walk when opened.
            if (_tab == 1)
              ValueListenableBuilder<String?>(
                valueListenable: JourneyFlow.activeJourneyId,
                builder: (context, journeyId, _) => WalkFlow(
                  api: widget.api,
                  relay: _relay,
                  journeyId: journeyId,
                ),
              )
            else
              const SizedBox.shrink(),
            PeopleScreen(
              api: widget.api,
              relay: _relay,
              tab: _peopleSubTab,
              openAlerts: _openAlerts,
            ),
            RespondScreen(api: widget.api, relay: _relay),
            ProfileScreen(api: widget.api),
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
              key: ValueKey('nav-walk-with-me'),
              icon: Icon(Icons.directions_walk_outlined),
              selectedIcon: Icon(Icons.directions_walk_rounded),
              label: 'Walk With Me',
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: _openAlerts > 0,
                backgroundColor: colors.error,
                label: Text('$_openAlerts'),
                child: const Icon(Icons.diversity_1_outlined),
              ),
              selectedIcon: Badge(
                isLabelVisible: _openAlerts > 0,
                backgroundColor: colors.error,
                label: Text('$_openAlerts'),
                child: const Icon(Icons.diversity_1_rounded),
              ),
              label: 'People',
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
            const NavigationDestination(
              icon: Icon(Icons.person_outline_rounded),
              selectedIcon: Icon(Icons.person_rounded),
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }
}
