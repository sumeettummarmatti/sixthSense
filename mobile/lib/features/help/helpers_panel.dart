import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/api/device_identity.dart';
import '../../core/contacts/contact_book.dart';
import '../../core/location/geo.dart';
import '../../core/location/live_location.dart';
import 'people_map.dart';

const _meColor = '#5B3FA8';
const _helperColor = '#1F7A8C';

/// On my journey screen while an alert is open: who is coming, how far they
/// are, and a small map with them and me. Like a ride app, but for help.
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

  String _name(Helper helper) {
    if (helper.isResponder) return helper.label ?? 'A verified responder';
    return names[helper.contactLinkId]?.name ?? 'Your contact';
  }

  ReceivedLocation? _locationOf(
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

  Widget _panel(
    BuildContext context,
    HelpView view,
    Map<String, ReceivedLocation> locations,
    Position? me,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final text = theme.textTheme;
    final people = <MapPerson>[
      if (me != null)
        MapPerson(
          latitude: me.latitude,
          longitude: me.longitude,
          color: _meColor,
          isMe: true,
        ),
      for (final helper in view.helpers)
        if (_locationOf(helper, locations) case final location?)
          MapPerson(
            latitude: location.latitude,
            longitude: location.longitude,
            color: _helperColor,
          ),
    ];
    final waiting = view.helpers.isEmpty;
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
                      ? '${_name(view.helpers.first)} is coming'
                      : '${view.helpers.length} people are coming',
                  style: text.titleMedium,
                ),
              ),
            ],
          ),
          if (people.length > 1) ...[
            const SizedBox(height: 10),
            PeopleMap(people: people, height: 170),
          ],
          for (final helper in view.helpers) ...[
            const SizedBox(height: 10),
            _HelperRow(
              name: _name(helper),
              helper: helper,
              location: _locationOf(helper, locations),
              me: me,
            ),
          ],
        ],
      ),
    );
  }
}

class _HelperRow extends StatelessWidget {
  const _HelperRow({
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
              ? colors.tertiaryContainer
              : colors.primaryContainer,
          child: Icon(
            helper.isResponder
                ? Icons.verified_user_rounded
                : Icons.favorite_rounded,
            size: 18,
            color: helper.isResponder
                ? colors.onTertiaryContainer
                : colors.onPrimaryContainer,
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
