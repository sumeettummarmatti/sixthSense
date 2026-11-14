import 'dart:async';

import 'package:flutter/material.dart';

import 'package:geolocator/geolocator.dart';

import '../../core/api/device_identity.dart';
import '../../core/location/geo.dart';
import '../../core/location/live_location.dart';
import '../../core/sos/live_audio.dart';
import '../sos/sos_widgets.dart';
import 'contact_alerts.dart';
import 'live_location_panel.dart';

/// The trusted contact's side of an alert. Shows only open alerts this person
/// is part of (rule 4); everything disappears once the alert is closed.
class ContactAlertsScreen extends StatefulWidget {
  const ContactAlertsScreen({
    super.key,
    this.api = const DemoApi(),
    this.pollInterval = const Duration(seconds: 5),
    this.relay,
    this.embedded = false,
  });

  final DemoApi api;
  final Duration pollInterval;

  /// Shares my location back to the person while I'm on my way (null in tests).
  final LiveLocationRelay? relay;

  /// Inside the People tab, which shows its own app bar.
  final bool embedded;

  @override
  State<ContactAlertsScreen> createState() => _ContactAlertsScreenState();
}

class _ContactAlertsScreenState extends State<ContactAlertsScreen> {
  List<ContactAlert>? _alerts;
  List<ListeningEscort> _escorts = const [];
  String? _error;
  final _busy = <String>{};
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(widget.pollInterval, (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Journeys I'm sharing my location with because I said "I'm on it".
  final _sharingBack = <String>{};

  Future<void> _refresh() async {
    try {
      final alerts = await widget.api.activeAlerts();
      if (mounted) {
        setState(() {
          _alerts = alerts;
          _error = null;
        });
      }
      await _syncSharingBack(alerts);
      await _refreshEscorts(alerts);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not reach the server.');
    }
  }

  /// Audio escorts I can listen to; stop playing anything that has ended.
  Future<void> _refreshEscorts(List<ContactAlert> alerts) async {
    if (widget.relay == null) return;
    try {
      final escorts = await widget.api.listeningEscorts();
      if (mounted) setState(() => _escorts = escorts);
      await LiveAudioPlayer.instance.keepOnly({
        for (final alert in alerts)
          if (alert.journeyId != null) alert.journeyId!,
        for (final escort in escorts) escort.journeyId,
      });
    } catch (_) {
      // Escorts are optional; alerts still work.
    }
  }

  Future<void> _askForEscort() async {
    List<SupportedPerson> people;
    try {
      people = await widget.api.supporting();
    } catch (_) {
      _show('Could not reach the server.');
      return;
    }
    if (!mounted) return;
    if (people.isEmpty) {
      _show('Nobody has added you as a trusted contact yet.');
      return;
    }
    final chosen = await showDialog<SupportedPerson>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Ask to keep someone company'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              'They get a request. Only they can start an audio escort, and they choose for how long.',
            ),
          ),
          for (final person in people)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(person),
              child: Text(person.ownerLabel),
            ),
        ],
      ),
    );
    if (chosen == null) return;
    try {
      await widget.api.askForEscort(chosen.contactLinkId);
      _show(
        'Asked ${chosen.ownerLabel}. You will be able to listen if they start one.',
      );
    } catch (_) {
      _show('Could not send the request.');
    }
  }

  /// Keep sharing back for alerts I'm helping with; stop for closed ones.
  Future<void> _syncSharingBack(List<ContactAlert> alerts) async {
    final relay = widget.relay;
    if (relay == null) return;
    final helping = {
      for (final alert in alerts)
        if (alert.iAmHelping && alert.journeyId != null)
          alert.journeyId!: alert,
    };
    for (final ended
        in _sharingBack.difference(helping.keys.toSet()).toList()) {
      _sharingBack.remove(ended);
      await relay.stopHelping(ended);
    }
    for (final entry in helping.entries) {
      if (relay.isHelping(entry.key)) {
        _sharingBack.add(entry.key);
        continue;
      }
      try {
        final owner = await widget.api.alertOwnerKeys(entry.value.id);
        if (await relay.startHelping(widget.api, owner)) {
          _sharingBack.add(entry.key);
        }
      } catch (_) {
        // Try again on the next refresh.
      }
    }
  }

  Future<void> _act(
    ContactAlert alert,
    Future<void> Function(String id) action,
    String done,
  ) async {
    setState(() => _busy.add(alert.id));
    try {
      await action(alert.id);
      if (mounted) _show(done);
    } on ApiException catch (error) {
      if (mounted) {
        _show(switch (error.detail) {
          'nothing_to_resolve' ||
          'nothing_to_raise' => 'This alert has already moved on.',
          _ => 'Could not send that (HTTP ${error.statusCode}).',
        });
      }
    } catch (_) {
      if (mounted) _show('Could not reach the server.');
    } finally {
      if (mounted) setState(() => _busy.remove(alert.id));
      await _refresh();
    }
  }

  void _show(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final alerts = _alerts;
    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(title: const Text('People you support')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            children: [
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      key: const ValueKey('support-accept-invite'),
                      onPressed: () async {
                        await acceptInviteFlow(context, widget.api);
                        await _refresh();
                      },
                      icon: const Icon(Icons.link_rounded),
                      label: const Text('Accept invite'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      key: const ValueKey('support-telegram'),
                      onPressed: () => linkTelegramFlow(context, widget.api),
                      icon: const Icon(Icons.send_rounded),
                      label: const Text('Telegram'),
                    ),
                  ),
                ],
              ),
              if (widget.relay != null) ...[
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    key: const ValueKey('ask-escort'),
                    onPressed: _askForEscort,
                    icon: const Icon(Icons.hearing_outlined),
                    label: const Text('Ask to keep someone company'),
                  ),
                ),
                for (final escort in _escorts)
                  Card(
                    key: ValueKey('escort-${escort.escortId}'),
                    margin: const EdgeInsets.only(top: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${escort.ownerLabel} started an audio escort',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Until ${TimeOfDay.fromDateTime(escort.endsAt).format(context)}. '
                            'Nothing is kept on your phone. If something sounds wrong, call them or 112.',
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            child: LiveAudioButton(
                              sessionId: escort.journeyId,
                              relay: widget.relay!,
                            ),
                          ),
                          const SizedBox(height: 10),
                          LiveLocationPanel(
                            journeyId: escort.journeyId,
                            ownerLabel: escort.ownerLabel,
                            relay: widget.relay,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 16),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!),
                ),
              if (alerts == null)
                const Padding(
                  padding: EdgeInsets.only(top: 48),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (alerts.isEmpty)
                const _NoAlerts()
              else
                for (final alert in alerts)
                  _AlertCard(
                    alert: alert,
                    busy: _busy.contains(alert.id),
                    relay: widget.relay,
                    onAck: () => _act(
                      alert,
                      widget.api.acknowledgeAlert,
                      widget.relay == null
                          ? 'Others know you are on it.'
                          : '${alert.ownerLabel} can now see you coming.',
                    ),
                    onResolve: () => _act(
                      alert,
                      widget.api.resolveAlert,
                      'Thanks. Everyone has been told.',
                    ),
                    onRaise: () => _act(
                      alert,
                      widget.api.raiseAlarm,
                      'Full alert raised to everyone.',
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoAlerts extends StatelessWidget {
  const _NoAlerts();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 48),
      child: Column(
        children: [
          Icon(
            Icons.notifications_none_rounded,
            size: 40,
            color: colors.primary,
          ),
          const SizedBox(height: 12),
          Text(
            'No open alerts',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'If someone who trusts you asks for help, it shows up here and on Telegram.',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({
    required this.alert,
    required this.busy,
    required this.onAck,
    required this.onResolve,
    required this.onRaise,
    this.relay,
  });

  final LiveLocationRelay? relay;
  final ContactAlert alert;
  final bool busy;
  final VoidCallback onAck;
  final VoidCallback onResolve;
  final VoidCallback onRaise;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final text = theme.textTheme;
    final opened = TimeOfDay.fromDateTime(alert.openedAt).format(context);
    final title = alert.fullEscalation
        ? '${alert.ownerLabel} needs help now'
        : '${alert.ownerLabel} missed a check-in';
    return Card(
      key: ValueKey('alert-${alert.id}'),
      margin: const EdgeInsets.only(bottom: 14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          // Red only for SOS / full alerts (design rule).
          color: alert.fullEscalation ? colors.error : colors.outline,
          width: alert.fullEscalation ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: text.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Since $opened',
              style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
            if (alert.covert) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  "Silent alarm: don't call them. Someone may be watching their phone.",
                  style: text.bodyMedium?.copyWith(
                    color: colors.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            if (alert.journeyId != null) ...[
              const SizedBox(height: 14),
              LiveLocationPanel(
                journeyId: alert.journeyId!,
                ownerLabel: alert.ownerLabel,
                relay: relay,
                helping: alert.iAmHelping,
              ),
              if (relay != null) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: LiveAudioButton(
                    sessionId: alert.journeyId!,
                    relay: relay!,
                  ),
                ),
              ],
            ],
            const SizedBox(height: 14),
            Text('Verification code', style: text.labelMedium),
            const SizedBox(height: 2),
            SelectableText(
              alert.verificationCode,
              key: const ValueKey('alert-code'),
              style: text.headlineSmall?.copyWith(
                letterSpacing: 2,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              'It must match the code in the Telegram message. If not, that message is fake.',
              style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            if (alert.iAmHelping)
              _OnMyWay(alert: alert, relay: relay)
            else ...[
              if (alert.acknowledged)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    alert.helpersGoing <= 1
                        ? 'Someone is on it.'
                        : '${alert.helpersGoing} people are on the way.',
                    style: text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: busy ? null : onAck,
                  child: Text(
                    alert.acknowledged ? "I'm going too" : "I'm on it",
                  ),
                ),
              ),
              if (relay != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${alert.ownerLabel} will see your live location while you go to them.',
                    style: text.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: busy ? null : onResolve,
                child: const Text("I've reached them, they're OK"),
              ),
            ),
            if (!alert.fullEscalation) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: busy ? null : onRaise,
                  style: TextButton.styleFrom(foregroundColor: colors.error),
                  child: const Text("I can't reach them, raise the alarm"),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// "You're on your way · 280 m · ~4 min walk" for a contact who is helping.
class _OnMyWay extends StatelessWidget {
  const _OnMyWay({required this.alert, required this.relay});

  final ContactAlert alert;
  final LiveLocationRelay? relay;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final relay = this.relay;
    Widget line(String label) => Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.directions_walk_rounded, color: colors.onPrimaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: colors.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    if (relay == null || alert.journeyId == null) {
      return line("You're on it. Others have been told.");
    }
    return ValueListenableBuilder<Position?>(
      valueListenable: relay.myPosition,
      builder: (context, me, _) =>
          ValueListenableBuilder<Map<String, ReceivedLocation>>(
            valueListenable: relay.received,
            builder: (context, locations, _) {
              final them = locations[alert.journeyId];
              if (me == null || them == null) {
                return line(
                  "You're on your way. ${alert.ownerLabel} can see you coming.",
                );
              }
              final meters = distanceMeters(
                me.latitude,
                me.longitude,
                them.latitude,
                them.longitude,
              );
              return line(
                meters < 40
                    ? "You're right next to ${alert.ownerLabel}."
                    : "You're on your way · ${walkLabel(meters)}",
              );
            },
          ),
    );
  }
}

/// A small banner for the home screen: checks for open alerts in the
/// background and opens [ContactAlertsScreen] when tapped.
class ContactAlertBanner extends StatefulWidget {
  const ContactAlertBanner({
    super.key,
    required this.api,
    this.pollInterval = const Duration(seconds: 10),
  });

  final DemoApi api;
  final Duration pollInterval;

  @override
  State<ContactAlertBanner> createState() => _ContactAlertBannerState();
}

class _ContactAlertBannerState extends State<ContactAlertBanner> {
  List<ContactAlert> _alerts = const [];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _check();
    _timer = Timer.periodic(widget.pollInterval, (_) => _check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    try {
      final alerts = await widget.api.activeAlerts();
      if (mounted) setState(() => _alerts = alerts);
    } catch (_) {
      // Offline or signed out: keep quiet; the screen itself shows errors.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_alerts.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final first = _alerts.first;
    final urgent = _alerts.any((alert) => alert.fullEscalation);
    final label = _alerts.length == 1
        ? (first.fullEscalation
              ? '${first.ownerLabel} needs help now'
              : '${first.ownerLabel} missed a check-in')
        : '${_alerts.length} people need you';
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Material(
        color: urgent ? colors.errorContainer : colors.primaryContainer,
        borderRadius: BorderRadius.circular(16),
        child: ListTile(
          key: const ValueKey('contact-alert-banner'),
          leading: Icon(
            Icons.warning_amber_rounded,
            color: urgent ? colors.onErrorContainer : colors.onPrimaryContainer,
          ),
          title: Text(label),
          subtitle: const Text('Tap to respond'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ContactAlertsScreen(api: widget.api),
              ),
            );
            _check();
          },
        ),
      ),
    );
  }
}
