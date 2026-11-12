import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../core/api/device_identity.dart';
import '../../core/location/live_location.dart';

/// Live location of someone I support, decrypted on this phone. Shown inside
/// their alert card; nothing is kept after the alert or journey ends.
class LiveLocationPanel extends StatefulWidget {
  const LiveLocationPanel({
    super.key,
    required this.journeyId,
    required this.ownerLabel,
    this.relay,
  });

  final String journeyId;
  final String ownerLabel;
  final LiveLocationRelay? relay;

  @override
  State<LiveLocationPanel> createState() => _LiveLocationPanelState();
}

class _LiveLocationPanelState extends State<LiveLocationPanel> {
  static const _mapStyleUrl = 'https://tiles.openfreemap.org/styles/liberty';

  MapLibreMapController? _controller;
  bool _styleLoaded = false;
  ReceivedLocation? _drawn;
  Timer? _clock;

  LiveLocationRelay get _relay => widget.relay ?? LiveLocationRelay.instance;

  @override
  void initState() {
    super.initState();
    // Re-render "updated N s ago" every few seconds.
    _clock = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  Future<void> _draw(ReceivedLocation location) async {
    final controller = _controller;
    if (controller == null || !_styleLoaded || identical(_drawn, location)) {
      return;
    }
    _drawn = location;
    final point = LatLng(location.latitude, location.longitude);
    await controller.clearCircles();
    // Accuracy ring (approximate: circleRadius is in screen pixels).
    await controller.addCircle(
      CircleOptions(
        geometry: point,
        circleColor: '#7C55C6',
        circleOpacity: 0.15,
        circleRadius: (location.accuracyMeters / 2).clamp(12, 60).toDouble(),
        circleStrokeColor: '#7C55C6',
        circleStrokeOpacity: 0.4,
        circleStrokeWidth: 1,
      ),
    );
    await controller.addCircle(
      CircleOptions(
        geometry: point,
        circleColor: '#5B3FA8',
        circleRadius: 8,
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 3,
      ),
    );
    await controller.animateCamera(CameraUpdate.newLatLngZoom(point, 17));
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
      builder: (context, locations, _) {
        final location = locations[widget.journeyId];
        if (location == null) {
          return Container(
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
        unawaited(_draw(location));
        final stale =
            DateTime.now().difference(location.takenAt).inMinutes >= 2;
        return Column(
          key: const ValueKey('live-location'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                height: 220,
                child: MapLibreMap(
                  styleString: _mapStyleUrl,
                  initialCameraPosition: CameraPosition(
                    target: LatLng(location.latitude, location.longitude),
                    zoom: 17,
                  ),
                  onMapCreated: (controller) => _controller = controller,
                  onStyleLoadedCallback: () {
                    _styleLoaded = true;
                    _drawn = null;
                    _draw(location);
                  },
                ),
              ),
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
            const SizedBox(height: 2),
            SelectableText(
              '${location.latitude.toStringAsFixed(6)}, ${location.longitude.toStringAsFixed(6)}',
              style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.directions_outlined),
                label: const Text('Get directions in your maps app'),
                onPressed: () => const DeviceIdentity().openUrl(
                  'https://www.google.com/maps/dir/?api=1&destination=${location.latitude},${location.longitude}',
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
