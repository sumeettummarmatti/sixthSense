import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../core/api/device_identity.dart';
import '../../core/location/geo.dart';
import '../../core/location/live_location.dart';
import '../../core/location/walk_route.dart';
import '../map/live_help_map.dart';
import '../map/live_map.dart';

/// Live location of someone I support, decrypted on this phone. Shown inside
/// their alert card; nothing is kept after the alert or journey ends. When I'm
/// on my way, I'm on the map too, with the walking route between us.
class LiveLocationPanel extends StatefulWidget {
  const LiveLocationPanel({
    super.key,
    required this.journeyId,
    required this.ownerLabel,
    this.relay,
    this.helping = false,
    this.whileWaiting,
  });

  /// Shown above the waiting note until the first precise fix arrives
  /// (for a responder: the rough area map).
  final Widget? whileWaiting;

  final String journeyId;
  final String ownerLabel;
  final LiveLocationRelay? relay;

  /// I said I'm going: show me and the route.
  final bool helping;

  @override
  State<LiveLocationPanel> createState() => _LiveLocationPanelState();
}

class _LiveLocationPanelState extends State<LiveLocationPanel> {
  Timer? _clock;
  final _router = WalkRouter();
  WalkRoute? _route;

  LiveLocationRelay get _relay => widget.relay ?? LiveLocationRelay.instance;

  @override
  void initState() {
    super.initState();
    // Re-render "updated N s ago" and refresh the route every few seconds.
    _clock = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      setState(() {});
      unawaited(_refreshRoute());
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  Future<void> _refreshRoute() async {
    if (!widget.helping) return;
    final me = _relay.myPosition.value;
    final them = _relay.received.value[widget.journeyId];
    if (me == null || them == null) return;
    final route = await _router.route(
      LatLng(me.latitude, me.longitude),
      LatLng(them.latitude, them.longitude),
    );
    if (mounted && route != null && route != _route) {
      setState(() => _route = route);
    }
  }

  String _ago(DateTime time) {
    final seconds = DateTime.now().difference(time).inSeconds;
    if (seconds < 10) return 'just now';
    if (seconds < 60) return '$seconds s ago';
    return '${seconds ~/ 60} min ago';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final text = theme.textTheme;
    return ValueListenableBuilder<Map<String, ReceivedLocation>>(
      valueListenable: _relay.received,
      builder: (context, locations, _) => ValueListenableBuilder<Position?>(
        valueListenable: _relay.myPosition,
        builder: (context, me, _) {
          final location = locations[widget.journeyId];
          if (location == null) {
            final extra = widget.whileWaiting;
            if (extra == null) return _waiting(colors, text);
            return Column(
              children: [
                extra,
                const SizedBox(height: 10),
                _waiting(colors, text),
              ],
            );
          }
          final stale =
              DateTime.now().difference(location.takenAt).inMinutes >= 2;
          final showMe = widget.helping && me != null;
          return Column(
            key: const ValueKey('live-location'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LiveMap(
                height: 230, // flat in cards: 3D is for the full-screen map
                route: widget.helping ? _route?.points : null,
                actors: [
                  MapActor(
                    id: 'traveller',
                    kind: ActorKind.traveller,
                    latitude: location.latitude,
                    longitude: location.longitude,
                    label: widget.ownerLabel,
                    inDanger: !stale,
                  ),
                  if (showMe)
                    MapActor(
                      id: 'me',
                      kind: ActorKind.me,
                      latitude: me.latitude,
                      longitude: me.longitude,
                      label: 'You',
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    stale ? Icons.location_off_outlined : Icons.my_location,
                    size: 18,
                    color: stale ? colors.onSurfaceVariant : colors.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${stale ? 'Last seen' : 'Live'} · within ${location.accuracyMeters.round()} m · ${_ago(location.takenAt)}',
                      style: text.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              if (showMe) ...[
                const SizedBox(height: 2),
                Text(
                  _route != null
                      ? 'You: ${_route!.minutes} min walk · ${distanceLabel(_route!.meters)}'
                      : 'You: ${walkLabel(distanceMeters(me.latitude, me.longitude, location.latitude, location.longitude))}',
                  style: text.titleMedium,
                ),
              ],
              const SizedBox(height: 2),
              SelectableText(
                '${location.latitude.toStringAsFixed(6)}, ${location.longitude.toStringAsFixed(6)}',
                style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      key: const ValueKey('open-helper-map'),
                      icon: const Icon(Icons.open_in_full_rounded),
                      label: const Text('Live map'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => HelperLiveMapPage(
                            relay: _relay,
                            journeyId: widget.journeyId,
                            personLabel: widget.ownerLabel,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.directions_walk_rounded),
                      label: const Text('Directions'),
                      onPressed: () => const DeviceIdentity().openUrl(
                        'https://www.google.com/maps/dir/?api=1&travelmode=walking'
                        '&destination=${location.latitude},${location.longitude}',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _waiting(ColorScheme colors, TextTheme text) => Container(
    key: const ValueKey('live-location-waiting'),
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: colors.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      children: [
        SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: colors.primary,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            "Waiting for ${widget.ownerLabel}'s live location. It is shared, encrypted, only while their journey is open.",
            style: text.bodySmall,
          ),
        ),
      ],
    ),
  );
}
