import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api/device_identity.dart';
import '../../core/location/live_location.dart';
import '../contacts/contact_alerts_screen.dart';
import '../contacts/my_people_screen.dart';
import '../journey/journey_flow.dart';

/// Signed-in home: my journey, my people, and the people I support.
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
  Timer? _poll;

  LiveLocationRelay get _relay => widget.relay ?? LiveLocationRelay.instance;

  @override
  void initState() {
    super.initState();
    // Listen for live locations of people I support (decrypted on this phone).
    unawaited(_relay.start(widget.api));
    _checkAlerts();
    _poll = Timer.periodic(widget.pollInterval, (_) => _checkAlerts());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _checkAlerts() async {
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
          ContactAlertsScreen(api: widget.api),
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
        ],
      ),
    );
  }
}
