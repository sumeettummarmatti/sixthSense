import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/api/device_identity.dart';
import '../../core/contacts/contact_book.dart';
import '../../core/location/geo.dart';
import '../../core/location/live_location.dart';
import '../map/live_help_map.dart';
import '../map/live_map.dart';

/// Name shown for a helper: responder's display name, or my contact's name.
String helperName(Helper helper, Map<String, LocalContact> names) {
  if (helper.isResponder) return helper.label ?? 'A verified responder';
  return names[helper.contactLinkId]?.name ?? 'Your contact';
}

/// Latest decrypted location of a helper (any of their devices).
ReceivedLocation? helperLocation(
  Helper helper,
  Map<String, ReceivedLocation> locations,
) {
  ReceivedLocation? latest;
  for (final key in helper.keys) {
    final location = locations[key.keyId];
    if (location != null &&
        (latest == null || location.takenAt.isAfter(latest.takenAt))) {
      latest = location;
    }
  }
  return latest;
}

/// Me (pulsing red during a full alert) plus everyone coming, labelled.
List<MapActor> travellerActors(
  HelpView view,
  Position? me,
  Map<String, ReceivedLocation> locations,
  Map<String, LocalContact> names,
) => [
  if (me != null)
    MapActor(
      id: 'me',
      kind: ActorKind.me,
      latitude: me.latitude,
      longitude: me.longitude,
      label: 'You',
      inDanger: view.fullAlert,
    ),
  for (final helper in view.helpers)
    if (helperLocation(helper, locations) case final at?)
      MapActor(
        id: helper.id,
        kind: helper.isResponder ? ActorKind.responder : ActorKind.contact,
        latitude: at.latitude,
        longitude: at.longitude,
        label: [
          helperName(helper, names),
          if (me != null && !helper.arrived)
            '${walkMinutes(distanceMeters(me.latitude, me.longitude, at.latitude, at.longitude))} min',
        ].join(' · '),
      ),
];

/// "Searching 500 m · 3 responders on duty nearby · 2 asked · 1 coming"
String? searchLine(HelpView view) {
  final search = view.search;
  if (search == null) return null;
  final parts = <String>[
    if (search.going < 2)
      'Searching ${distanceLabel(search.radiusMeters.toDouble())}',
    '${search.onDutyNearby} responder${search.onDutyNearby == 1 ? '' : 's'} on duty nearby',
    '${search.asked} asked',
    '${search.going} coming',
  ];
  return parts.join(' · ');
}

/// On my journey screen while an alert is open: who is coming, how far they
/// are, and a live map with them gliding towards me. Like a ride app.
class HelpersPanel extends StatelessWidget {
  const HelpersPanel({
    super.key,
    required this.help,
    required this.relay,
    required this.names,
  });

  final ValueListenable<HelpView> help;
  final LiveLocationRelay relay;
  final Map<String, LocalContact> names;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<HelpView>(
      valueListenable: help,
      builder: (context, view, _) {
        if (!view.anyAlert && view.helpers.isEmpty) {
          return const SizedBox.shrink();
        }
        return ValueListenableBuilder<Map<String, ReceivedLocation>>(
          valueListenable: relay.helperLocations,
          builder: (context, locations, _) => ValueListenableBuilder<Position?>(
            valueListenable: relay.myPosition,
            builder: (context, me, _) => _panel(context, view, locations, me),
          ),
        );
      },
    );
  }

  Widget _panel(
    BuildContext context,
    HelpView view,
    Map<String, ReceivedLocation> locations,
    Position? me,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final text = theme.textTheme;
    final actors = travellerActors(view, me, locations, names);
    final waiting = view.helpers.isEmpty;
    final search = searchLine(view);
    return Container(
      key: const ValueKey('helpers-panel'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                waiting ? Icons.wifi_tethering : Icons.directions_walk_rounded,
                color: colors.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  waiting
                      ? (view.fullAlert
                            ? 'Alert sent. Asking your contacts and responders nearby…'
                            : 'Your contacts have been alerted…')
                      : view.helpers.length == 1
                      ? '${helperName(view.helpers.first, names)} is coming'
                      : '${view.helpers.length} people are coming',
                  style: text.titleMedium,
                ),
              ),
            ],
          ),
          if (search != null) ...[
            const SizedBox(height: 6),
            Text(
              search,
              key: const ValueKey('search-line'),
              style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
          if (actors.isNotEmpty && mapsEnabled) ...[
            const SizedBox(height: 10),
            LiveMap(
              actors: actors,
              height: 170,
              searchRadiusMeters: (view.search?.going ?? 2) < 2
                  ? view.search!.radiusMeters.toDouble()
                  : null,
              linkHelpersToTraveller: true,
            ),
          ],
          for (final helper in view.helpers) ...[
            const SizedBox(height: 10),
            HelperTile(
              name: helperName(helper, names),
              helper: helper,
              location: helperLocation(helper, locations),
              me: me,
            ),
          ],
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const ValueKey('open-live-map'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => TravellerLiveMapPage(
                    help: help,
                    relay: relay,
                    names: names,
                  ),
                ),
              ),
              icon: const Icon(Icons.open_in_full_rounded, size: 18),
              label: const Text('Full-screen live map'),
            ),
          ),
        ],
      ),
    );
  }
}

class HelperTile extends StatelessWidget {
  const HelperTile({
    super.key,
    required this.name,
    required this.helper,
    required this.location,
    required this.me,
  });

  final String name;
  final Helper helper;
  final ReceivedLocation? location;
  final Position? me;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final location = this.location;
    final me = this.me;
    String status;
    if (helper.arrived) {
      status = 'Says they have reached you';
    } else if (location != null && me != null) {
      final meters = distanceMeters(
        me.latitude,
        me.longitude,
        location.latitude,
        location.longitude,
      );
      status = meters < 40 ? 'Right next to you' : walkLabel(meters);
    } else {
      status = 'On the way · location coming…';
    }
    return Row(
      key: ValueKey('helper-${helper.id}'),
      children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: helper.isResponder
              ? const Color(0xFFD3EFE4)
              : const Color(0xFFD5EEF2),
          child: Icon(
            helper.isResponder
                ? Icons.verified_user_rounded
                : Icons.favorite_rounded,
            size: 18,
            color: helper.isResponder
                ? const Color(0xFF0B6E4F)
                : const Color(0xFF1F7A8C),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                helper.isResponder ? '$name · verified responder' : name,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                status,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
