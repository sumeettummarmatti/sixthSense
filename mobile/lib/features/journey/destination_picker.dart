import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../core/location/geo.dart';

/// Where I'm going, picked like in a ride app: search with suggestions, or
/// long-press the map to drop a pin. The destination stays on this phone
/// (rule 2); searches go to the free OpenStreetMap search (Photon) without
/// any account or id.
class Destination {
  const Destination({required this.label, this.latitude, this.longitude});

  final String label;
  final double? latitude;
  final double? longitude;

  bool get hasPoint => latitude != null && longitude != null;
}

class DestinationPicker extends StatefulWidget {
  const DestinationPicker({
    super.key,
    required this.controller,
    required this.onChanged,
  });

  final TextEditingController controller;

  /// Called with the destination and, when known, the walking minutes to it.
  final void Function(Destination destination, int? walkMinutes) onChanged;

  @override
  State<DestinationPicker> createState() => _DestinationPickerState();
}

class _DestinationPickerState extends State<DestinationPicker>
    with WidgetsBindingObserver {
  static const _style = 'https://tiles.openfreemap.org/styles/liberty';

  MapLibreMapController? _map;
  bool _styleLoaded = false;
  Position? _me;
  Destination? _picked;
  List<_Place> _suggestions = const [];
  Timer? _debounce;
  bool _searching = false;
  int _searchId = 0;
  bool _settingText = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTyped);
    WidgetsBinding.instance.addObserver(this);
    if (mapsEnabled) unawaited(_locate());
  }

  // Fresh map after its tab was hidden or the app was in the background
  // (the old drawing surface goes black).
  int _generation = 0;
  bool _visible = true;

  void _remount() {
    _generation++;
    _map = null;
    _styleLoaded = false;
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible && !_visible) _remount();
    _visible = visible;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _remount();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTyped);
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _locate() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission != LocationPermission.always &&
          permission != LocationPermission.whileInUse) {
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      if (!mounted) return;
      setState(() => _me = position);
      await _draw(moveCamera: true);
    } catch (_) {
      // The picker still works by typing a name.
    }
  }

  void _onTyped() {
    if (_settingText) return;
    final query = widget.controller.text.trim();
    // Typing a new name forgets the old pin.
    if (_picked != null && _picked!.label != widget.controller.text) {
      _picked = null;
      unawaited(_draw());
    }
    widget.onChanged(Destination(label: query), null);
    _debounce?.cancel();
    if (!mapsEnabled || query.length < 3) {
      _searchId++; // drop answers to older searches
      if (_suggestions.isNotEmpty || _searching) {
        setState(() {
          _suggestions = const [];
          _searching = false;
        });
      }
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 600), () => _search(query));
  }

  Future<void> _search(String query) async {
    final id = ++_searchId;
    setState(() => _searching = true);
    try {
      final params = {
        'q': query,
        'limit': '5',
        if (_me != null) 'lat': '${_me!.latitude}',
        if (_me != null) 'lon': '${_me!.longitude}',
      };
      final places = await _photon(
        Uri.https('photon.komoot.io', '/api/', params),
      );
      if (!mounted || id != _searchId) return;
      setState(() => _suggestions = places);
    } catch (_) {
      if (mounted && id == _searchId) setState(() => _suggestions = const []);
    } finally {
      if (mounted && id == _searchId) setState(() => _searching = false);
    }
  }

  static Future<List<_Place>> _photon(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'SixthSense-pilot/0.1');
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final body = await utf8.decoder.bind(response).join();
      final features =
          (jsonDecode(body) as Map<String, dynamic>)['features'] as List? ??
          const [];
      return [
        for (final feature in features.cast<Map<String, dynamic>>())
          _Place.fromFeature(feature),
      ];
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _choose(Destination destination) async {
    FocusScope.of(context).unfocus();
    _settingText = true;
    widget.controller.text = destination.label;
    _settingText = false;
    setState(() {
      _picked = destination;
      _suggestions = const [];
    });
    widget.onChanged(destination, _walkMinutes());
    await _draw(moveCamera: true);
  }

  Future<void> _dropPin(LatLng point) async {
    final fallback =
        'Pin ${point.latitude.toStringAsFixed(4)}, ${point.longitude.toStringAsFixed(4)}';
    await _choose(
      Destination(
        label: fallback,
        latitude: point.latitude,
        longitude: point.longitude,
      ),
    );
    try {
      final places = await _photon(
        Uri.https('photon.komoot.io', '/reverse', {
          'lat': '${point.latitude}',
          'lon': '${point.longitude}',
        }),
      );
      if (!mounted || places.isEmpty || _picked?.label != fallback) return;
      await _choose(
        Destination(
          label: places.first.label,
          latitude: point.latitude,
          longitude: point.longitude,
        ),
      );
    } catch (_) {
      // Keep the coordinates as the name.
    }
  }

  double? _distance() {
    final me = _me, picked = _picked;
    if (me == null || picked == null || !picked.hasPoint) return null;
    return distanceMeters(
      me.latitude,
      me.longitude,
      picked.latitude!,
      picked.longitude!,
    );
  }

  int? _walkMinutes() {
    final meters = _distance();
    return meters == null ? null : walkMinutes(meters);
  }

  Future<void> _draw({bool moveCamera = false}) async {
    final map = _map;
    if (map == null || !_styleLoaded) return;
    await map.clearCircles();
    final me = _me, picked = _picked;
    if (me != null) {
      await map.addCircle(
        CircleOptions(
          geometry: LatLng(me.latitude, me.longitude),
          circleColor: '#5B3FA8',
          circleRadius: 8,
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 3,
        ),
      );
    }
    if (picked != null && picked.hasPoint) {
      await map.addCircle(
        CircleOptions(
          geometry: LatLng(picked.latitude!, picked.longitude!),
          circleColor: '#1F7A8C',
          circleRadius: 10,
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 3,
        ),
      );
    }
    if (!moveCamera) return;
    if (me != null && picked != null && picked.hasPoint) {
      await map.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(
              me.latitude < picked.latitude! ? me.latitude : picked.latitude!,
              me.longitude < picked.longitude!
                  ? me.longitude
                  : picked.longitude!,
            ),
            northeast: LatLng(
              me.latitude > picked.latitude! ? me.latitude : picked.latitude!,
              me.longitude > picked.longitude!
                  ? me.longitude
                  : picked.longitude!,
            ),
          ),
          left: 50,
          right: 50,
          top: 50,
          bottom: 50,
        ),
      );
    } else if (picked != null && picked.hasPoint) {
      await map.animateCamera(
        CameraUpdate.newLatLngZoom(
          LatLng(picked.latitude!, picked.longitude!),
          16,
        ),
      );
    } else if (me != null) {
      await map.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(me.latitude, me.longitude), 15),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final meters = _distance();
    final eta = meters == null
        ? null
        : TimeOfDay.fromDateTime(
            DateTime.now().add(Duration(minutes: walkMinutes(meters))),
          ).format(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('journey-destination'),
          controller: widget.controller,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search_rounded),
            hintText: 'Search a place, or long-press the map',
            border: const OutlineInputBorder(),
            suffixIcon: _searching
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : null,
          ),
        ),
        if (_suggestions.isNotEmpty)
          Card(
            margin: const EdgeInsets.only(top: 6),
            child: Column(
              children: [
                for (final place in _suggestions)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.place_outlined),
                    title: Text(place.name),
                    subtitle: place.area.isEmpty ? null : Text(place.area),
                    trailing: _me == null
                        ? null
                        : Text(
                            distanceLabel(
                              distanceMeters(
                                _me!.latitude,
                                _me!.longitude,
                                place.latitude,
                                place.longitude,
                              ),
                            ),
                          ),
                    onTap: () => _choose(
                      Destination(
                        label: place.label,
                        latitude: place.latitude,
                        longitude: place.longitude,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (mapsEnabled) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              height: 220,
              child: MapLibreMap(
                key: ValueKey(_generation),
                styleString: _style,
                initialCameraPosition: const CameraPosition(
                  target: LatLng(
                    12.9716,
                    77.5946,
                  ), // Bengaluru until GPS answers
                  zoom: 11,
                ),
                gestureRecognizers: {
                  Factory<OneSequenceGestureRecognizer>(
                    EagerGestureRecognizer.new,
                  ),
                },
                onMapCreated: (map) => _map = map,
                tiltGesturesEnabled: false,
                onStyleLoadedCallback: () {
                  _styleLoaded = true;
                  _map
                      ?.setLayerVisibility('building-3d', false)
                      .catchError((_) {});
                  unawaited(_draw(moveCamera: true));
                },
                onMapLongClick: (_, point) => _dropPin(point),
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(
              meters == null ? Icons.touch_app_outlined : Icons.directions_walk,
              size: 18,
              color: colors.primary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                meters == null
                    ? (_me == null
                          ? 'Finding where you are…'
                          : 'Purple is you. Search or long-press to drop a pin.')
                    : '${walkLabel(meters)} · arrive about $eta',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Place {
  const _Place(this.name, this.area, this.latitude, this.longitude);

  final String name;
  final String area;
  final double latitude;
  final double longitude;

  String get label => area.isEmpty ? name : '$name, $area';

  factory _Place.fromFeature(Map<String, dynamic> feature) {
    final props = (feature['properties'] as Map).cast<String, dynamic>();
    final coords = (feature['geometry'] as Map)['coordinates'] as List;
    final street = [
      props['housenumber'],
      props['street'],
    ].whereType<String>().join(' ');
    final name =
        (props['name'] as String?) ?? (street.isEmpty ? 'Place' : street);
    final area = [
      props['district'] ?? props['locality'],
      props['city'],
    ].whereType<String>().where((part) => part != name).toSet().join(', ');
    return _Place(
      name,
      area,
      (coords[1] as num).toDouble(),
      (coords[0] as num).toDouble(),
    );
  }
}
