import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../core/api/device_identity.dart';
import '../../core/contacts/contact_book.dart';
import '../../core/location/geo.dart';
import '../../core/location/live_location.dart';
import '../../core/location/walk_route.dart';
import '../help/helpers_panel.dart';
import 'live_map.dart';

/// Full-screen live map for the person who asked for help: me pulsing red,
/// the responder search radius, everyone coming gliding towards me, counts
/// at the top and who is coming in a sheet at the bottom.
class TravellerLiveMapPage extends StatefulWidget {
  const TravellerLiveMapPage({
    super.key,
    required this.help,
    required this.relay,
    required this.names,
  });

  final ValueListenable<HelpView> help;
  final LiveLocationRelay relay;
  final Map<String, LocalContact> names;

  @override
  State<TravellerLiveMapPage> createState() => _TravellerLiveMapPageState();
}

class _TravellerLiveMapPageState extends State<TravellerLiveMapPage> {
  final mapKey = GlobalKey<LiveMapState>();

  ValueListenable<HelpView> get help => widget.help;
  LiveLocationRelay get relay => widget.relay;
  Map<String, LocalContact> get names => widget.names;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ValueListenableBuilder<HelpView>(
        valueListenable: help,
        builder: (context, view, _) =>
            ValueListenableBuilder<Map<String, ReceivedLocation>>(
              valueListenable: relay.helperLocations,
              builder: (context, locations, _) => ValueListenableBuilder<Position?>(
                valueListenable: relay.myPosition,
                builder: (context, me, _) {
                  final actors = travellerActors(view, me, locations, names);
                  final search = searchLine(view);
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: actors.isEmpty
                            ? const Center(
                                child: Text('Finding your location…'),
                              )
                            : LiveMap(
                                key: mapKey,
                                actors: actors,
                                searchRadiusMeters:
                                    (view.search?.going ?? 2) < 2
                                    ? view.search!.radiusMeters.toDouble()
                                    : null,
                                linkHelpersToTraveller: true,
                                padding: const EdgeInsets.fromLTRB(
                                  40,
                                  140,
                                  40,
                                  260,
                                ),
                              ),
                      ),
                      _TopBar(
                        title: view.helpers.isEmpty
                            ? (view.fullAlert
                                  ? 'Getting you help'
                                  : 'Alert sent')
                            : view.helpers.length == 1
                            ? '${helperName(view.helpers.first, names)} is coming'
                            : '${view.helpers.length} people are coming',
                        subtitle: search,
                        danger: view.fullAlert,
                      ),
                      _RecenterButton(
                        onTap: () => mapKey.currentState?.recenter(),
                      ),
                      _BottomSheet(
                        children: [
                          if (view.helpers.isEmpty)
                            const Text(
                              'Your contacts and verified responders nearby have been alerted. '
                              'You will see them here as soon as someone is on the way.',
                            ),
                          for (final helper in view.helpers)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: HelperTile(
                                name: helperName(helper, names),
                                helper: helper,
                                location: helperLocation(helper, locations),
                                me: me,
                              ),
                            ),
                          const _CallLine(),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
      ),
    );
  }
}

/// Full-screen live map for a contact or responder going to help: the person
/// pulsing red, me, the walking route between us with the time it takes.
class HelperLiveMapPage extends StatefulWidget {
  const HelperLiveMapPage({
    super.key,
    required this.relay,
    required this.journeyId,
    required this.personLabel,
  });

  final LiveLocationRelay relay;
  final String journeyId;
  final String personLabel;

  @override
  State<HelperLiveMapPage> createState() => _HelperLiveMapPageState();
}

class _HelperLiveMapPageState extends State<HelperLiveMapPage> {
  final _router = WalkRouter();
  final _mapKey = GlobalKey<LiveMapState>();
  WalkRoute? _route;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refreshRoute();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refreshRoute());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refreshRoute() async {
    final me = widget.relay.myPosition.value;
    final them = widget.relay.received.value[widget.journeyId];
    if (me == null || them == null) return;
    final route = await _router.route(
      LatLng(me.latitude, me.longitude),
      LatLng(them.latitude, them.longitude),
    );
    if (mounted && route != null) setState(() => _route = route);
  }

  @override
  Widget build(BuildContext context) {
    final relay = widget.relay;
    return Scaffold(
      body: ValueListenableBuilder<Map<String, ReceivedLocation>>(
        valueListenable: relay.received,
        builder: (context, locations, _) => ValueListenableBuilder<Position?>(
          valueListenable: relay.myPosition,
          builder: (context, me, _) {
            final them = locations[widget.journeyId];
            final actors = [
              if (them != null)
                MapActor(
                  id: 'traveller',
                  kind: ActorKind.traveller,
                  latitude: them.latitude,
                  longitude: them.longitude,
                  label: widget.personLabel,
                  inDanger: true,
                ),
              if (me != null)
                MapActor(
                  id: 'me',
                  kind: ActorKind.me,
                  latitude: me.latitude,
                  longitude: me.longitude,
                  label: 'You',
                ),
            ];
            final straight = (me != null && them != null)
                ? distanceMeters(
                    me.latitude,
                    me.longitude,
                    them.latitude,
                    them.longitude,
                  )
                : null;
            final route = _route;
            final title = straight == null
                ? 'Waiting for live location…'
                : straight < 40
                ? 'You are right there'
                : route != null
                ? '${route.minutes} min walk · ${distanceLabel(route.meters)}'
                : walkLabel(straight);
            final ago = them == null
                ? null
                : DateTime.now().difference(them.takenAt).inSeconds;
            return Stack(
              children: [
                Positioned.fill(
                  child: actors.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : LiveMap(
                          key: _mapKey,
                          actors: actors,
                          route: route?.points,
                          padding: const EdgeInsets.fromLTRB(40, 140, 40, 230),
                        ),
                ),
                _TopBar(
                  title: title,
                  subtitle: them == null
                      ? null
                      : '${widget.personLabel} · live · within ${them.accuracyMeters.round()} m · '
                            '${ago! < 10 ? 'just now' : '$ago s ago'}',
                  danger: true,
                ),
                _RecenterButton(onTap: () => _mapKey.currentState?.recenter()),
                _BottomSheet(
                  children: [
                    if (them != null)
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          icon: const Icon(Icons.directions_walk_rounded),
                          label: const Text(
                            'Walking directions in Google Maps',
                          ),
                          onPressed: () => const DeviceIdentity().openUrl(
                            'https://www.google.com/maps/dir/?api=1&travelmode=walking'
                            '&destination=${them.latitude},${them.longitude}',
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      'They see you coming. Their location disappears from your phone when the alert ends.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 6),
                    const _CallLine(),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.title, this.subtitle, this.danger = false});

  final String title;
  final String? subtitle;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Material(
          elevation: 6,
          shadowColor: Colors.black26,
          borderRadius: BorderRadius.circular(20),
          color: colors.surface,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 16, 10),
            child: Row(
              children: [
                const BackButton(),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          if (danger)
                            Container(
                              width: 10,
                              height: 10,
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                color: colors.error,
                                shape: BoxShape.circle,
                              ),
                            ),
                          Expanded(
                            child: Text(
                              title,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          subtitle!,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RecenterButton extends StatelessWidget {
  const _RecenterButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 16,
      bottom: 250,
      child: FloatingActionButton.small(
        heroTag: null,
        tooltip: 'Show everyone',
        onPressed: onTap,
        child: const Icon(Icons.center_focus_strong_rounded),
      ),
    );
  }
}

class _BottomSheet extends StatelessWidget {
  const _BottomSheet({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Material(
        elevation: 12,
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: colors.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  ...children,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CallLine extends StatelessWidget {
  const _CallLine();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return TextButton.icon(
      style: TextButton.styleFrom(foregroundColor: colors.error),
      onPressed: () => const DeviceIdentity().openUrl('tel:112'),
      icon: const Icon(Icons.call_rounded),
      label: const Text('Danger right now? Call 112'),
    );
  }
}
