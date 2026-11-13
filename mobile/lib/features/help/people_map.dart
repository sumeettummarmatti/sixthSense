import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../core/location/geo.dart';

/// One dot on a [PeopleMap].
class MapPerson {
  const MapPerson({
    required this.latitude,
    required this.longitude,
    required this.color,
    this.isMe = false,
    this.roughRadiusPixels,
  });

  final double latitude;
  final double longitude;
  final String color;
  final bool isMe;

  /// Draw a soft circle instead of a dot (rough area only).
  final double? roughRadiusPixels;
}

/// A small map that keeps a few people in view (me and whoever is coming).
class PeopleMap extends StatefulWidget {
  const PeopleMap({super.key, required this.people, this.height = 190});

  final List<MapPerson> people;
  final double height;

  @override
  State<PeopleMap> createState() => _PeopleMapState();
}

class _PeopleMapState extends State<PeopleMap> {
  static const _style = 'https://tiles.openfreemap.org/styles/liberty';

  MapLibreMapController? _controller;
  bool _styleLoaded = false;
  String _drawn = '';
  bool _drawing = false;

  @override
  void didUpdateWidget(PeopleMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    unawaited(_draw());
  }

  String _signature() => widget.people
      .map(
        (p) =>
            '${p.latitude.toStringAsFixed(5)},${p.longitude.toStringAsFixed(5)},${p.color}',
      )
      .join('|');

  Future<void> _draw() async {
    final controller = _controller;
    if (controller == null || !_styleLoaded || _drawing) return;
    final signature = _signature();
    if (signature == _drawn || widget.people.isEmpty) return;
    _drawing = true;
    try {
      _drawn = signature;
      await controller.clearCircles();
      for (final person in widget.people) {
        final point = LatLng(person.latitude, person.longitude);
        if (person.roughRadiusPixels != null) {
          await controller.addCircle(
            CircleOptions(
              geometry: point,
              circleColor: person.color,
              circleOpacity: 0.18,
              circleRadius: person.roughRadiusPixels!,
              circleStrokeColor: person.color,
              circleStrokeOpacity: 0.5,
              circleStrokeWidth: 1,
            ),
          );
          continue;
        }
        await controller.addCircle(
          CircleOptions(
            geometry: point,
            circleColor: person.color,
            circleRadius: person.isMe ? 9 : 8,
            circleStrokeColor: '#FFFFFF',
            circleStrokeWidth: 3,
          ),
        );
      }
      await controller.animateCamera(_camera());
    } finally {
      _drawing = false;
    }
  }

  CameraUpdate _camera() {
    final people = widget.people;
    if (people.length == 1) {
      return CameraUpdate.newLatLngZoom(
        LatLng(people.first.latitude, people.first.longitude),
        16,
      );
    }
    final lats = people.map((p) => p.latitude);
    final lngs = people.map((p) => p.longitude);
    return CameraUpdate.newLatLngBounds(
      LatLngBounds(
        southwest: LatLng(lats.reduce(min), lngs.reduce(min)),
        northeast: LatLng(lats.reduce(max), lngs.reduce(max)),
      ),
      left: 48,
      right: 48,
      top: 40,
      bottom: 40,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!mapsEnabled || widget.people.isEmpty) return const SizedBox.shrink();
    final first = widget.people.first;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: widget.height,
        child: MapLibreMap(
          styleString: _style,
          initialCameraPosition: CameraPosition(
            target: LatLng(first.latitude, first.longitude),
            zoom: 15,
          ),
          onMapCreated: (controller) => _controller = controller,
          onStyleLoadedCallback: () {
            _styleLoaded = true;
            _drawn = '';
            unawaited(_draw());
          },
        ),
      ),
    );
  }
}
