import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../core/routes/safe_routes.dart';
import '../map/live_map.dart';

/// During a journey: the route I chose and where I am on it.
class JourneyRouteScreen extends StatefulWidget {
  const JourneyRouteScreen({
    super.key,
    required this.route,
    required this.destination,
  });

  final RankedRoute route;
  final String destination;

  @override
  State<JourneyRouteScreen> createState() => _JourneyRouteScreenState();
}

class _JourneyRouteScreenState extends State<JourneyRouteScreen> {
  StreamSubscription<Position>? _positions;
  Position? _me;

  @override
  void initState() {
    super.initState();
    _positions = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen((p) => setState(() => _me = p), onError: (_) {});
  }

  @override
  void dispose() {
    _positions?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final route = widget.route;
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final me = _me;
    final off = me == null
        ? null
        : distanceToRoute(me.latitude, me.longitude, route.points);
    return Scaffold(
      appBar: AppBar(title: const Text('Your route')),
      body: Column(
        children: [
          Expanded(
            child: LiveMap(
              route: [for (final p in route.points) LatLng(p.$1, p.$2)],
              actors: [
                if (me != null)
                  MapActor(
                    id: 'me',
                    kind: ActorKind.me,
                    latitude: me.latitude,
                    longitude: me.longitude,
                    label: 'You',
                  ),
                if (route.points.isNotEmpty)
                  MapActor(
                    id: 'destination',
                    kind: ActorKind.contact,
                    latitude: route.points.last.$1,
                    longitude: route.points.last.$2,
                    label: 'Destination',
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.destination, style: text.titleMedium),
                  const SizedBox(height: 4),
                  Text(route.summary, style: text.bodyLarge),
                  if (route.facts.isNotEmpty)
                    Text(
                      route.facts.take(3).join(' · '),
                      style: text.bodySmall,
                    ),
                  if (off != null && off > 150) ...[
                    const SizedBox(height: 6),
                    Text(
                      'You are about ${off.round()} m off this route.',
                      key: const ValueKey('off-route-label'),
                      style: text.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    'Ranked by what is around this way. No route is labelled safe. '
                    'Volume Down 5 times sends an SOS if you need it.',
                    style: text.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
