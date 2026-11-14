import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../core/location/geo.dart';

/// Who is on a [LiveMap].
enum ActorKind { me, traveller, contact, responder, roughArea }

class MapActor {
  const MapActor({
    required this.id,
    required this.kind,
    required this.latitude,
    required this.longitude,
    this.label = '',
    this.inDanger = false,
  });

  final String id;
  final ActorKind kind;
  final double latitude;
  final double longitude;
  final String label;

  /// Pulsing red ring (SOS / full alert).
  final bool inDanger;

  LatLng get point => LatLng(latitude, longitude);
}

/// The live map used everywhere help is happening: tilted 3D streets, markers
/// that glide between GPS fixes (no jumps), a pulsing ring around the person
/// in danger, the responder search radius, a walking route for helpers and
/// dashed lines from helpers to the traveller. Like a ride app, for help.
class LiveMap extends StatefulWidget {
  const LiveMap({
    super.key,
    required this.actors,
    this.height,
    this.threeD = false,
    this.searchRadiusMeters,
    this.route,
    this.linkHelpersToTraveller = false,
    this.padding = const EdgeInsets.all(56),
    this.roughRadiusMeters = 150,
  });

  final List<MapActor> actors;

  /// Null fills the parent (full screen).
  final double? height;
  final bool threeD;

  /// Drawn around the traveller (or me, if no traveller) while searching.
  final double? searchRadiusMeters;

  /// Walking route to draw (helper's phone only).
  final List<LatLng>? route;

  /// Dashed straight lines from each helper to the traveller / me.
  final bool linkHelpersToTraveller;

  /// Extra room around the people when fitting the camera (bottom sheets).
  final EdgeInsets padding;
  final double roughRadiusMeters;

  @override
  State<LiveMap> createState() => LiveMapState();
}

class LiveMapState extends State<LiveMap>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _style = 'https://tiles.openfreemap.org/styles/liberty';
  static const _colors = {
    'me': '#5B3FA8',
    'traveller': '#B3261E',
    'contact': '#1F7A8C',
    'responder': '#0B6E4F',
    'roughArea': '#B3261E',
  };

  MapLibreMapController? _map;
  bool _ready = false;
  late final Ticker _ticker;
  Duration _elapsed = Duration.zero;
  Duration _lastFrame = Duration.zero;

  // Gliding: each marker moves from where it is drawn to its new fix.
  final _shown = <String, LatLng>{};
  final _from = <String, LatLng>{};
  Duration _moveStart = Duration.zero;
  static const _moveTime = Duration(milliseconds: 1400);

  Set<String> _fittedIds = {};
  DateTime _lastFitAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _userTouchedAt = DateTime.fromMillisecondsSinceEpoch(0);
  Size _size = const Size(360, 240);

  @override
  void initState() {
    super.initState();
    for (final actor in widget.actors) {
      _shown[actor.id] = actor.point;
    }
    _ticker = createTicker(_onTick)..start();
    WidgetsBinding.instance.addObserver(this);
  }

  // The map's drawing surface is lost when its tab is hidden or the app goes
  // to the background; build a fresh map when it is shown again.
  int _generation = 0;
  bool _visible = true;

  void _remount() {
    _generation++;
    _map = null;
    _ready = false;
    _lastActorsDrawn = '';
    _lastStaticDrawn = '';
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
  void didUpdateWidget(LiveMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    for (final actor in widget.actors) {
      final shown = _shown[actor.id];
      if (shown == null) {
        _shown[actor.id] = actor.point;
      } else if (shown != actor.point) {
        _from[actor.id] = shown;
      }
    }
    _shown.removeWhere((id, _) => widget.actors.every((a) => a.id != id));
    _moveStart = _elapsed;
    if (_ready) {
      unawaited(_drawStatic());
      _maybeFit();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    super.dispose();
  }

  /// Re-centre on everyone (the "recentre" button).
  void recenter() {
    _userTouchedAt = DateTime.fromMillisecondsSinceEpoch(0);
    _maybeFit(force: true);
  }

  bool _drawing = false;
  String _lastActorsDrawn = '';

  void _onTick(Duration elapsed) {
    _elapsed = elapsed;
    // ~10 frames a second, and never start a frame before the last one is
    // done: piling up map updates froze the app on slower phones.
    if (!_ready ||
        _drawing ||
        elapsed - _lastFrame < const Duration(milliseconds: 100)) {
      return;
    }
    _lastFrame = elapsed;
    final t = ((elapsed - _moveStart).inMilliseconds / _moveTime.inMilliseconds)
        .clamp(0.0, 1.0);
    final eased = Curves.easeInOut.transform(t);
    for (final actor in widget.actors) {
      final from = _from[actor.id];
      if (from == null) {
        _shown[actor.id] = actor.point;
        continue;
      }
      _shown[actor.id] = LatLng(
        from.latitude + (actor.latitude - from.latitude) * eased,
        from.longitude + (actor.longitude - from.longitude) * eased,
      );
      if (t >= 1) _from.remove(actor.id);
    }
    _drawing = true;
    _drawMoving().whenComplete(() => _drawing = false);
  }

  // ---- drawing --------------------------------------------------------------

  static Map<String, dynamic> _collection(List<Map<String, dynamic>> f) => {
    'type': 'FeatureCollection',
    'features': f,
  };

  static Map<String, dynamic> _point(LatLng p, Map<String, dynamic> props) => {
    'type': 'Feature',
    'properties': props,
    'geometry': {
      'type': 'Point',
      'coordinates': [p.longitude, p.latitude],
    },
  };

  static Map<String, dynamic> _line(List<LatLng> points) => {
    'type': 'Feature',
    'properties': <String, dynamic>{},
    'geometry': {
      'type': 'LineString',
      'coordinates': [
        for (final p in points) [p.longitude, p.latitude],
      ],
    },
  };

  static Map<String, dynamic> _circle(LatLng c, double meters) {
    const steps = 72;
    final latR = meters / 111320;
    final lngR = meters / (111320 * cos(c.latitude * pi / 180));
    final ring = [
      for (var i = 0; i <= steps; i++)
        [
          c.longitude + lngR * cos(2 * pi * i / steps),
          c.latitude + latR * sin(2 * pi * i / steps),
        ],
    ];
    return {
      'type': 'Feature',
      'properties': <String, dynamic>{},
      'geometry': {
        'type': 'Polygon',
        'coordinates': [ring],
      },
    };
  }

  MapActor? get _traveller {
    for (final kind in [ActorKind.traveller, ActorKind.me]) {
      for (final a in widget.actors) {
        if (a.kind == kind) return a;
      }
    }
    return null;
  }

  Future<void> _setup() async {
    final map = _map!;
    if (!widget.threeD) {
      // Flat, ride-app style: no extruded buildings.
      try {
        await map.setLayerVisibility('building-3d', false);
      } catch (_) {}
    }
    final empty = _collection(const []);
    for (final id in [
      'ss-area',
      'ss-route',
      'ss-links',
      'ss-pulse',
      'ss-actors',
    ]) {
      await map.addGeoJsonSource(id, empty);
    }
    await map.addFillLayer(
      'ss-area',
      'ss-area-fill',
      const FillLayerProperties(fillColor: ['get', 'color'], fillOpacity: 0.10),
    );
    await map.addLineLayer(
      'ss-area',
      'ss-area-edge',
      const LineLayerProperties(
        lineColor: ['get', 'color'],
        lineWidth: 1.5,
        lineOpacity: 0.6,
        lineDasharray: [2, 2],
      ),
    );
    await map.addLineLayer(
      'ss-route',
      'ss-route-casing',
      const LineLayerProperties(
        lineColor: '#FFFFFF',
        lineWidth: 9,
        lineCap: 'round',
        lineJoin: 'round',
      ),
    );
    await map.addLineLayer(
      'ss-route',
      'ss-route-line',
      const LineLayerProperties(
        lineColor: '#1F7A8C',
        lineWidth: 5,
        lineCap: 'round',
        lineJoin: 'round',
      ),
    );
    await map.addLineLayer(
      'ss-links',
      'ss-links-line',
      const LineLayerProperties(
        lineColor: '#1F7A8C',
        lineWidth: 2.5,
        lineOpacity: 0.8,
        lineDasharray: [1.5, 1.5],
      ),
    );
    await map.addCircleLayer(
      'ss-pulse',
      'ss-pulse-ring',
      const CircleLayerProperties(
        circleColor: '#B3261E',
        circleRadius: ['get', 'r'],
        circleOpacity: ['get', 'o'],
        circlePitchAlignment: 'map',
      ),
    );
    await map.addCircleLayer(
      'ss-actors',
      'ss-actors-halo',
      const CircleLayerProperties(
        circleColor: ['get', 'color'],
        circleRadius: 16,
        circleOpacity: 0.18,
        circlePitchAlignment: 'map',
      ),
      filter: [
        '!=',
        ['get', 'kind'],
        'roughArea',
      ],
    );
    await map.addCircleLayer(
      'ss-actors',
      'ss-actors-dot',
      const CircleLayerProperties(
        circleColor: ['get', 'color'],
        circleRadius: 8.5,
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 3,
        circlePitchAlignment: 'map',
        circleSortKey: ['get', 'z'],
      ),
      filter: [
        '!=',
        ['get', 'kind'],
        'roughArea',
      ],
    );
    await map.addSymbolLayer(
      'ss-actors',
      'ss-actors-label',
      const SymbolLayerProperties(
        textField: ['get', 'label'],
        textFont: ['Noto Sans Bold'],
        textSize: 12.5,
        // Labels step aside (below, above, left, right) instead of piling up.
        textVariableAnchor: ['top', 'bottom', 'left', 'right'],
        textRadialOffset: 1.3,
        textJustify: 'auto',
        textColor: '#1C1B1F',
        textHaloColor: '#FFFFFF',
        textHaloWidth: 2,
        symbolSortKey: [
          '-',
          10,
          ['get', 'z'],
        ],
      ),
    );
    _ready = true;
    await _drawStatic();
    await _drawMoving();
    _maybeFit(force: true);
  }

  String _lastStaticDrawn = '';

  Future<void> _drawStatic() async {
    final map = _map;
    if (map == null) return;
    final anchor = _traveller?.point;
    final signature = [
      widget.searchRadiusMeters,
      anchor?.latitude.toStringAsFixed(4),
      anchor?.longitude.toStringAsFixed(4),
      widget.route?.length,
      widget.route?.lastOrNull,
      for (final a in widget.actors.where((a) => a.kind == ActorKind.roughArea))
        a.point,
    ].join('|');
    if (signature == _lastStaticDrawn) return;
    _lastStaticDrawn = signature;
    final areas = <Map<String, dynamic>>[];
    final centre = _traveller;
    final radius = widget.searchRadiusMeters;
    if (centre != null && radius != null) {
      areas.add(
        _circle(centre.point, radius)..['properties'] = {'color': '#B3261E'},
      );
    }
    for (final a in widget.actors.where((a) => a.kind == ActorKind.roughArea)) {
      areas.add(
        _circle(a.point, widget.roughRadiusMeters)
          ..['properties'] = {'color': '#B3261E'},
      );
    }
    await map.setGeoJsonSource('ss-area', _collection(areas));
    final route = widget.route;
    await map.setGeoJsonSource(
      'ss-route',
      _collection([if (route != null && route.length > 1) _line(route)]),
    );
  }

  Future<void> _drawMoving() async {
    final map = _map;
    if (map == null) return;
    final signature = [
      for (final a in widget.actors)
        '${a.id}:${(_shown[a.id] ?? a.point).latitude.toStringAsFixed(6)},'
            '${(_shown[a.id] ?? a.point).longitude.toStringAsFixed(6)}:${a.label}',
    ].join('|');
    final moved = signature != _lastActorsDrawn;
    final pulsing = widget.actors.any((a) => a.inDanger);
    if (!moved && !pulsing) return; // nothing changed: send nothing
    if (!moved) {
      await _drawPulse(map);
      return;
    }
    _lastActorsDrawn = signature;
    final features = <Map<String, dynamic>>[];
    for (final actor in widget.actors) {
      final at = _shown[actor.id] ?? actor.point;
      features.add(
        _point(at, {
          'kind': actor.kind.name,
          'color': _colors[actor.kind.name],
          'label': actor.label,
          // Me / the person in danger on top of helpers standing next to them.
          'z': actor.kind == ActorKind.me || actor.kind == ActorKind.traveller
              ? 3
              : 1,
        }),
      );
    }
    await map.setGeoJsonSource('ss-actors', _collection(features));
    if (pulsing) await _drawPulse(map);

    if (widget.linkHelpersToTraveller) {
      final target = _traveller;
      await map.setGeoJsonSource(
        'ss-links',
        _collection([
          if (target != null)
            for (final a in widget.actors)
              if (a.kind == ActorKind.contact || a.kind == ActorKind.responder)
                _line([
                  _shown[a.id] ?? a.point,
                  _shown[target.id] ?? target.point,
                ]),
        ]),
      );
    }
  }

  /// A ring that grows and fades every 1.6 s around anyone in danger.
  Future<void> _drawPulse(MapLibreMapController map) async {
    final phase = (_elapsed.inMilliseconds % 1600) / 1600;
    await map.setGeoJsonSource(
      'ss-pulse',
      _collection([
        for (final actor in widget.actors.where((a) => a.inDanger))
          _point(_shown[actor.id] ?? actor.point, {
            'r': 10 + 34 * phase,
            'o': 0.45 * (1 - phase),
          }),
      ]),
    );
  }

  // ---- camera ---------------------------------------------------------------

  /// Keep everyone in view: on new people, and every 15 s as they move,
  /// unless the user moved the map in the last 20 s.
  void _maybeFit({bool force = false}) {
    final map = _map;
    if (map == null || widget.actors.isEmpty) return;
    final ids = widget.actors.map((a) => a.id).toSet();
    final now = DateTime.now();
    final userMoved =
        now.difference(_userTouchedAt) < const Duration(seconds: 20);
    final due =
        !setEquals(ids, _fittedIds) ||
        now.difference(_lastFitAt) > const Duration(seconds: 15);
    if (!force && (userMoved || !due)) return;
    _fittedIds = ids;
    _lastFitAt = now;
    unawaited(map.animateCamera(CameraUpdate.newCameraPosition(_fitCamera())));
  }

  CameraPosition _fitCamera() {
    final points = [
      for (final a in widget.actors) a.point,
      if (widget.route != null) ...widget.route!,
    ];
    final lats = points.map((p) => p.latitude);
    final lngs = points.map((p) => p.longitude);
    final minLat = lats.reduce(min), maxLat = lats.reduce(max);
    final minLng = lngs.reduce(min), maxLng = lngs.reduce(max);
    final centre = LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);
    var span = max(
      distanceMeters(minLat, centre.longitude, maxLat, centre.longitude),
      distanceMeters(centre.latitude, minLng, centre.latitude, maxLng),
    );
    final radius = widget.searchRadiusMeters;
    if (radius != null) span = max(span, radius * 2);
    span = max(span, 180); // never closer than a street or two
    // A tilted camera shows less ground near the bottom: zoom out a bit and
    // aim slightly past the middle so nearer people stay on screen.
    if (widget.threeD) span *= 1.6;
    final pad = widget.padding;
    final usable = max(
      120.0,
      min(_size.width - pad.horizontal, _size.height - pad.vertical),
    );
    // Web-mercator metres per pixel at zoom z: 156543 * cos(lat) / 2^z.
    final zoom =
        log(156543 * cos(centre.latitude * pi / 180) * usable / span) / ln2;
    return CameraPosition(
      target: centre,
      zoom: zoom.clamp(12.0, 18.0),
      tilt: widget.threeD ? (widget.height == null ? 55 : 45) : 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!mapsEnabled || widget.actors.isEmpty) return const SizedBox.shrink();
    final first = widget.actors.first;
    final map = LayoutBuilder(
      builder: (context, constraints) {
        _size = Size(
          constraints.maxWidth.isFinite ? constraints.maxWidth : 360,
          constraints.maxHeight.isFinite ? constraints.maxHeight : 240,
        );
        final fullScreen = widget.height == null;
        final mapView = Listener(
          onPointerDown: (_) => _userTouchedAt = DateTime.now(),
          child: MapLibreMap(
            key: ValueKey(_generation),
            styleString: _style,
            initialCameraPosition: CameraPosition(
              target: first.point,
              zoom: 15.5,
              tilt: widget.threeD ? 55 : 0,
            ),
            compassEnabled: fullScreen,
            rotateGesturesEnabled: fullScreen,
            tiltGesturesEnabled: false,
            scrollGesturesEnabled: fullScreen,
            zoomGesturesEnabled: fullScreen,
            doubleClickZoomEnabled: fullScreen,
            gestureRecognizers: fullScreen
                ? {
                    Factory<OneSequenceGestureRecognizer>(
                      EagerGestureRecognizer.new,
                    ),
                  }
                : const {},
            onMapCreated: (map) => _map = map,
            onStyleLoadedCallback: () => unawaited(_setup()),
          ),
        );
        // A card map is a picture: the page scrolls over it.
        return fullScreen ? mapView : IgnorePointer(child: mapView);
      },
    );
    if (widget.height == null) return map;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(height: widget.height, child: map),
    );
  }
}
