import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../core/routes/safe_routes.dart';
import '../map/live_map.dart';
import 'destination_picker.dart';

/// Walking routes to the chosen destination, ranked for this hour by what is
/// around them (streetlights, open places, bus stops, police, hospitals,
/// anonymous place reports). The traveller picks one; it stays on the phone.
class SafeRoutesPanel extends StatefulWidget {
  const SafeRoutesPanel({
    super.key,
    required this.destination,
    required this.onSelected,
    this.api = const SafeRoutesApi(),
  });

  final Destination? destination;
  final ValueChanged<RankedRoute?> onSelected;
  final SafeRoutesApi api;

  @override
  State<SafeRoutesPanel> createState() => _SafeRoutesPanelState();
}

class _SafeRoutesPanelState extends State<SafeRoutesPanel> {
  RankedRoutes? _routes;
  int? _selected;
  String? _unavailable;
  bool _loading = false;
  Position? _me;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(SafeRoutesPanel old) {
    super.didUpdateWidget(old);
    final a = old.destination, b = widget.destination;
    if (a?.latitude != b?.latitude || a?.longitude != b?.longitude) _load();
  }

  Future<void> _load() async {
    final destination = widget.destination;
    final request = ++_request;
    if (destination == null || !destination.hasPoint) {
      setState(() {
        _routes = null;
        _unavailable = null;
        _loading = false;
      });
      widget.onSelected(null);
      return;
    }
    setState(() {
      _loading = true;
      _unavailable = null;
    });
    try {
      final me = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      final routes = await widget.api.routes(
        fromLat: me.latitude,
        fromLon: me.longitude,
        toLat: destination.latitude!,
        toLon: destination.longitude!,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _me = me;
        _routes = routes;
        _selected = routes.recommended;
        _loading = false;
      });
      widget.onSelected(routes.routes[routes.recommended]);
    } on RoutesUnavailable catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _routes = null;
        _unavailable = error.reason;
        _loading = false;
      });
      widget.onSelected(null);
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        _routes = null;
        _unavailable = 'no_location';
        _loading = false;
      });
      widget.onSelected(null);
    }
  }

  void _choose(int index) {
    setState(() => _selected = index);
    widget.onSelected(_routes!.routes[index]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final colors = theme.colorScheme;
    if (widget.destination?.hasPoint != true) return const SizedBox.shrink();
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.only(top: 16),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 10),
            Text('Comparing walking routes for this hour…'),
          ],
        ),
      );
    }
    final unavailable = _unavailable;
    if (unavailable != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Text(
          switch (unavailable) {
            'outside_area' => 'Ranked routes cover Indiranagar for now. Your journey still works the same here.',
            'no_location' =>
              'Could not find where you are, so routes were not compared.',
            _ => 'Route ranking is not reachable right now. Your journey still works.',
          },
          key: const ValueKey('routes-unavailable'),
          style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
      );
    }
    final routes = _routes;
    if (routes == null) return const SizedBox.shrink();
    final selected = routes.routes[_selected ?? routes.recommended];
    final me = _me;
    return Column(
      key: const ValueKey('safe-routes'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        Text('Which way?', style: text.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Ranked for the ${routes.timeBand} by what is around each way. '
          'No route is labelled safe.',
          style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        LiveMap(
          height: 200,
          route: [for (final p in selected.points) LatLng(p.$1, p.$2)],
          actors: [
            if (me != null)
              MapActor(
                id: 'me',
                kind: ActorKind.me,
                latitude: me.latitude,
                longitude: me.longitude,
                label: 'You',
              ),
            if (selected.points.isNotEmpty)
              MapActor(
                id: 'destination',
                kind: ActorKind.contact,
                latitude: selected.points.last.$1,
                longitude: selected.points.last.$2,
                label: 'Destination',
              ),
          ],
        ),
        const SizedBox(height: 10),
        for (final (index, route) in routes.routes.indexed)
          _RouteOption(
            key: ValueKey('route-$index'),
            route: route,
            title: index == routes.recommended
                ? 'Recommended'
                : index == routes.shortest
                ? 'Shortest'
                : 'Another way',
            selected: index == (_selected ?? routes.recommended),
            onTap: () => _choose(index),
          ),
      ],
    );
  }
}

class _RouteOption extends StatelessWidget {
  const _RouteOption({
    super.key,
    required this.route,
    required this.title,
    required this.selected,
    required this.onTap,
  });

  final RankedRoute route;
  final String title;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final text = theme.textTheme;
    final strong = route.evidence == 'Strong evidence of concern';
    final details = [
      ...route.why,
      ...route.facts,
    ].where((line) => line != 'shortest route').take(3).join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? colors.primary : colors.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: selected ? colors.primary : colors.outline,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$title · ${route.summary}',
                      style: text.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (details.isNotEmpty)
                      Text(details, style: text.bodySmall),
                    if (route.evidence != 'Insufficient data')
                      Text(
                        route.evidence,
                        style: text.bodySmall?.copyWith(
                          // Red only for strong evidence (design rule); never green.
                          color: strong
                              ? colors.error
                              : colors.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
