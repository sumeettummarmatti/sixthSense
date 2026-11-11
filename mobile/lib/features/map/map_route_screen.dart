import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../reports/report_flow.dart';

class MapRouteScreen extends StatefulWidget {
  const MapRouteScreen({super.key, required this.destination});

  final String destination;

  @override
  State<MapRouteScreen> createState() => _MapRouteScreenState();
}

class _MapRouteScreenState extends State<MapRouteScreen> {
  static const _mapStyleUrl = 'https://tiles.openfreemap.org/styles/liberty';
  static const _fallbackCenter = LatLng(20.5937, 78.9629);

  MapLibreMapController? _controller;
  LatLng? _currentLocation;
  bool _styleLoaded = false;
  bool _locating = false;

  Future<void> _centerOnCurrentLocation() async {
    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _showMessage('Turn on location services to center the map.');
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _showMessage('Location permission is needed only to center the map.');
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
        ),
      );
      final point = LatLng(position.latitude, position.longitude);
      _currentLocation = point;
      await _controller?.animateCamera(CameraUpdate.newLatLngZoom(point, 15));
      await _drawCurrentLocation();
    } on PermissionDeniedException {
      _showMessage('Location permission was denied.');
    } on LocationServiceDisabledException {
      _showMessage('Turn on location services to center the map.');
    } catch (_) {
      _showMessage('Could not get your location. Try again.');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _drawCurrentLocation() async {
    final controller = _controller;
    final point = _currentLocation;
    if (controller == null || point == null || !_styleLoaded) return;
    await controller.clearCircles();
    await controller.addCircle(
      CircleOptions(
        geometry: point,
        circleColor: '#7C55C6',
        circleRadius: 9,
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 3,
      ),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Map and route preview')),
      body: Stack(
        children: [
          MapLibreMap(
            styleString: _mapStyleUrl,
            initialCameraPosition: const CameraPosition(
              target: _fallbackCenter,
              zoom: 4,
            ),
            trackCameraPosition: true,
            onMapCreated: (controller) => _controller = controller,
            onStyleLoadedCallback: () {
              _styleLoaded = true;
              _drawCurrentLocation();
            },
          ),
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'YOUR DESTINATION',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.destination,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        const Icon(Icons.info_outline_rounded, size: 18),
                        const SizedBox(width: 7),
                        Text(
                          'Insufficient data',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            right: 16,
            bottom: 264,
            child: FloatingActionButton.small(
              heroTag: 'center-current-location',
              tooltip: 'Center on my location',
              onPressed: _locating ? null : _centerOnCurrentLocation,
              child: _locating
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.my_location_rounded),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Card(
                margin: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Route options',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'The routing and published-risk services are not connected yet. No route recommendation is available, and this map does not label any place safe.',
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '© OpenStreetMap · OpenFreeMap',
                        style: TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        key: const ValueKey('open-report-flow'),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const ReportFlow(),
                          ),
                        ),
                        icon: const Icon(Icons.report_outlined),
                        label: const Text('Report a place issue'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
