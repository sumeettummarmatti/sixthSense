import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/api/device_identity.dart';
import '../../core/location/geo.dart';
import '../../core/location/live_location.dart';
import '../contacts/live_location_panel.dart';
import '../face_scan/face_scan_screen.dart';
import '../sos/sos_widgets.dart';
import '../map/live_map.dart';
import '../verification/verification_flow.dart';

/// Verified responders (F6): go on duty, get asked when someone nearby
/// presses SOS, and say "I'm going". Until then only a rough area (~110 m)
/// and distance are shown; after it, their precise live location (E2E).
///
/// Verifying identity (ID + selfie) is all it takes: there is no approval
/// step. Saying "I'm going" needs a fresh face scan, checked by the server in
/// the same request, before the traveller's location is shared.
class RespondScreen extends StatefulWidget {
  const RespondScreen({
    super.key,
    required this.api,
    this.relay,
    this.pollInterval = const Duration(seconds: 5),
    this.faceScanCamera,
  });

  final DemoApi api;
  final LiveLocationRelay? relay;
  final Duration pollInterval;

  /// Front camera + on-device face count for the scan (tests inject one).
  final FaceScanCamera? faceScanCamera;

  @override
  State<RespondScreen> createState() => _RespondScreenState();
}

class _RespondScreenState extends State<RespondScreen> {
  ResponderMe? _me;
  String? _verificationStatus;
  List<ResponderOffer> _offers = const [];
  String? _error;
  bool _busy = false;
  bool _onDuty = false;
  Position? _position;
  Timer? _poll;
  Timer? _presence;
  final _helpingWith = <String>{}; // journey ids I share my location with

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(widget.pollInterval, (_) => _refreshOffers());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _presence?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final me = await widget.api.responderMe();
      final verification = await widget.api.verificationMe();
      final wasOnDuty = await widget.api.identity.readValue('on_duty') == '1';
      if (!mounted) return;
      setState(() {
        _me = me;
        _verificationStatus = verification['status'] as String?;
        _error = null;
      });
      if (me.approved && wasOnDuty && !_onDuty) await _setOnDuty(true);
      await _refreshOffers();
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not reach the server.');
    }
  }

  Future<void> _apply() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _ApplyDialog(),
    );
    if (name == null || !mounted) return;
    if (_verificationStatus != 'verified') {
      final verified = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => VerificationFlowScreen(api: widget.api),
        ),
      );
      if (verified != true || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      final me = await widget.api.applyAsResponder(name);
      if (mounted) {
        setState(() {
          _me = me;
          _verificationStatus = 'verified';
        });
      }
    } catch (_) {
      _show('Could not send your application.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyExistingApplication() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => VerificationFlowScreen(api: widget.api),
      ),
    );
    if (mounted) await _load();
  }

  Future<bool> _locationAllowed() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  Future<void> _setOnDuty(bool on) async {
    if (on && !await _locationAllowed()) {
      _show('Allow location so people nearby can be matched with you.');
      return;
    }
    setState(() => _onDuty = on);
    await widget.api.identity.saveValue('on_duty', on ? '1' : null);
    _presence?.cancel();
    if (on) {
      await _sendPresence();
      _presence = Timer.periodic(
        const Duration(minutes: 1),
        (_) => _sendPresence(),
      );
    } else {
      try {
        await widget.api.goOffDuty();
      } catch (_) {}
    }
  }

  Future<void> _sendPresence() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      if (mounted) setState(() => _position = position);
      await widget.api.sendPresence(position.latitude, position.longitude);
    } catch (_) {
      // Next minute.
    }
  }

  Future<void> _refreshOffers() async {
    if (!(_me?.approved ?? false)) return;
    try {
      final offers = await widget.api.responderOffers();
      if (!mounted) return;
      setState(() => _offers = offers);
      await _syncHelping(offers);
    } catch (_) {}
  }

  /// Share my location with the people I'm going to; stop when alerts close.
  Future<void> _syncHelping(List<ResponderOffer> offers) async {
    final relay = widget.relay;
    if (relay == null) return;
    final going = {
      for (final offer in offers)
        if (offer.going && offer.journeyId != null) offer.journeyId!: offer,
    };
    for (final ended in _helpingWith.difference(going.keys.toSet()).toList()) {
      _helpingWith.remove(ended);
      await relay.stopHelping(ended);
    }
    for (final entry in going.entries) {
      if (relay.isHelping(entry.key)) {
        _helpingWith.add(entry.key);
        continue;
      }
      try {
        // Idempotent: returns the traveller's keys again.
        final owner = await widget.api.goingToHelp(entry.value.id);
        if (await relay.startHelping(widget.api, owner)) {
          _helpingWith.add(entry.key);
        }
      } catch (_) {}
    }
  }

  /// "I'm going" with a fresh face scan: the server checks it in the same
  /// request and only then shares the traveller's precise live location.
  Future<void> _going(ResponderOffer offer) async {
    setState(() => _busy = true);
    OwnerKeys? owner;
    String? problem;
    try {
      await FaceScanScreen.open(
        context,
        title: 'I\'m going',
        reason:
            'Before you see their live location, confirm that you, the '
            'verified responder, are holding this phone.',
        actionLabel: 'tell them you are coming and share live location',
        camera: widget.faceScanCamera,
        submit: (scan) async {
          try {
            owner = await widget.api.goingToHelp(offer.id, scan: scan);
            return null;
          } on ApiException catch (error) {
            final faceProblem = faceScanProblem(error);
            if (faceProblem != null) return faceProblem; // retry the scan
            problem = error.detail == 'enough_helpers'
                ? 'Two people are already going. Thank you for offering.'
                : 'Could not send that (${error.detail}).';
            return null;
          }
        },
      );
      final keys = owner;
      if (keys != null) {
        final shared = await widget.relay?.startHelping(widget.api, keys);
        if (shared ?? false) _helpingWith.add(keys.journeyId);
        _show(
          'Thank you. They can see you coming. Head to their live location.',
        );
      } else if (problem != null) {
        _show(problem!);
      }
    } catch (_) {
      _show('Could not reach the server.');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refreshOffers();
    }
  }

  Future<void> _simple(Future<void> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
      _show(done);
    } catch (_) {
      _show('Could not reach the server.');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refreshOffers();
    }
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final me = _me;
    return Scaffold(
      appBar: AppBar(title: const Text('Respond nearby')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!),
              ),
            if (me == null && _error == null)
              const Padding(
                padding: EdgeInsets.only(top: 48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (me != null &&
                (!me.approved || _verificationStatus != 'verified'))
              _NotYet(
                me: me,
                busy: _busy,
                verificationStatus: _verificationStatus,
                onApply: _apply,
                onVerify: _verifyExistingApplication,
              )
            else if (me != null) ...[
              _DutyCard(
                name: me.displayName ?? 'You',
                onDuty: _onDuty,
                position: _position,
                onChanged: _busy ? null : _setOnDuty,
              ),
              const SizedBox(height: 16),
              if (_offers.isEmpty)
                _Quiet(onDuty: _onDuty)
              else
                for (final offer in _offers)
                  _OfferCard(
                    offer: offer,
                    busy: _busy,
                    relay: widget.relay,
                    myPosition: _position,
                    onGoing: () => _going(offer),
                    onDecline: () => _simple(
                      () => widget.api.declineOffer(offer.id),
                      'OK. Others nearby are being asked too.',
                    ),
                    onArrived: () => _simple(
                      () => widget.api.arrivedAtOffer(offer.id),
                      'They have been told you are there.',
                    ),
                  ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NotYet extends StatelessWidget {
  const _NotYet({
    required this.me,
    required this.busy,
    required this.verificationStatus,
    required this.onApply,
    required this.onVerify,
  });

  final ResponderMe me;
  final bool busy;
  final String? verificationStatus;
  final VoidCallback onApply;
  final VoidCallback onVerify;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final revoked = me.status == 'revoked';
    // Applied, but the identity check is not done (or has expired).
    final needsVerification =
        !revoked && me.status != 'none' && verificationStatus != 'verified';
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [colors.primary, colors.secondary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.volunteer_activism_rounded,
            color: colors.onPrimary,
            size: 32,
          ),
          const SizedBox(height: 10),
          Text(
            revoked
                ? 'Your responder access was removed.'
                : needsVerification
                ? 'Verify your identity to start helping'
                : 'Help people near you',
            style: theme.textTheme.titleLarge?.copyWith(
              color: colors.onPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            needsVerification
                ? 'Upload your ID portrait and take a selfie. Once it matches you can go on duty straight away.'
                : 'When someone within a few minutes\' walk presses SOS, verified responders on duty are asked to go. You only see a rough area until you say "I\'m going".',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onPrimary.withValues(alpha: 0.92),
            ),
          ),
          const SizedBox(height: 14),
          if (me.status == 'none')
            FilledButton.tonal(
              key: const ValueKey('become-responder'),
              onPressed: busy ? null : onApply,
              child: const Text('Become a responder'),
            )
          else if (needsVerification)
            FilledButton.tonal(
              key: const ValueKey('continue-verification'),
              onPressed: busy ? null : onVerify,
              child: const Text('Start face match'),
            ),
        ],
      ),
    );
  }
}

class _DutyCard extends StatelessWidget {
  const _DutyCard({
    required this.name,
    required this.onDuty,
    required this.position,
    required this.onChanged,
  });

  final String name;
  final bool onDuty;
  final Position? position;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: onDuty ? colors.primaryContainer : colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: SwitchListTile(
        key: const ValueKey('on-duty'),
        contentPadding: const EdgeInsets.fromLTRB(18, 10, 12, 10),
        value: onDuty,
        onChanged: onChanged,
        title: Text(
          onDuty ? 'On duty · $name' : 'Off duty',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        subtitle: Text(
          onDuty
              ? 'Your rough area (about 100 m) is refreshed every minute and forgotten 5 minutes after you stop. Keep this app open.'
              : 'Turn on when you are free to help someone nearby.',
        ),
      ),
    );
  }
}

class _Quiet extends StatelessWidget {
  const _Quiet({required this.onDuty});

  final bool onDuty;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 32),
      child: Column(
        children: [
          Icon(Icons.radar_rounded, size: 44, color: colors.primary),
          const SizedBox(height: 10),
          Text(
            onDuty ? 'No requests nearby' : 'You are off duty',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            onDuty
                ? 'If someone close by presses SOS, it shows up here and on Telegram.'
                : 'Nobody will be matched with you until you go on duty.',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _OfferCard extends StatelessWidget {
  const _OfferCard({
    required this.offer,
    required this.busy,
    required this.relay,
    required this.myPosition,
    required this.onGoing,
    required this.onDecline,
    required this.onArrived,
  });

  final ResponderOffer offer;
  final bool busy;
  final LiveLocationRelay? relay;
  final Position? myPosition;
  final VoidCallback onGoing;
  final VoidCallback onDecline;
  final VoidCallback onArrived;

  Widget _roughMap() => LiveMap(
    height: 180,
    roughRadiusMeters: 150,
    actors: [
      MapActor(
        id: 'area',
        kind: ActorKind.roughArea,
        latitude: offer.roughLatitude!,
        longitude: offer.roughLongitude!,
        label: 'Around here',
      ),
      if (myPosition != null)
        MapActor(
          id: 'me',
          kind: ActorKind.me,
          latitude: myPosition!.latitude,
          longitude: myPosition!.longitude,
          label: 'You',
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final text = theme.textTheme;
    final since = TimeOfDay.fromDateTime(offer.openedAt).format(context);
    return Card(
      key: ValueKey('offer-${offer.id}'),
      margin: const EdgeInsets.only(bottom: 14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: colors.error, width: 2), // red only for SOS
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              offer.going
                  ? 'You are going to help'
                  : 'Someone nearby needs help',
              style: text.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              offer.going
                  ? 'Since $since · they can see you coming'
                  : 'About ${distanceLabel(offer.distanceMeters.toDouble())} away · ~${offer.walkMinutes} min walk · since $since',
              style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
            if (offer.covert) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Silent alarm: approach calmly, do not shout or call out to them.',
                  style: TextStyle(
                    color: colors.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            if (!offer.going) ...[
              if (offer.roughLatitude != null) _roughMap(),
              const SizedBox(height: 6),
              Text(
                'Rough area only. You see exactly where they are after you say you are going. '
                '${offer.helpersGoing > 0 ? '${offer.helpersGoing} already going.' : ''}',
                style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const ValueKey('offer-going'),
                  onPressed: busy ? null : onGoing,
                  icon: const Icon(Icons.directions_run_rounded),
                  label: const Text("I'm going"),
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: busy ? null : onDecline,
                  child: const Text("I can't right now"),
                ),
              ),
            ] else ...[
              if (offer.journeyId != null)
                LiveLocationPanel(
                  journeyId: offer.journeyId!,
                  ownerLabel: 'Person in need',
                  relay: relay,
                  helping: true,
                  whileWaiting: offer.roughLatitude == null
                      ? null
                      : _roughMap(),
                ),
              if (offer.journeyId != null && relay != null) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: LiveAudioButton(
                    sessionId: offer.journeyId!,
                    relay: relay!,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              if (offer.arrived)
                Text(
                  'You told them you are there. Stay with them; call 112 if needed.',
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                )
              else
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: busy ? null : onArrived,
                    child: const Text("I've reached them"),
                  ),
                ),
            ],
            const SizedBox(height: 6),
            Text(
              'If anyone is in danger, call 112 first.',
              style: text.bodySmall?.copyWith(color: colors.error),
            ),
          ],
        ),
      ),
    );
  }
}

class _ApplyDialog extends StatefulWidget {
  const _ApplyDialog();

  @override
  State<_ApplyDialog> createState() => _ApplyDialogState();
}

class _ApplyDialogState extends State<_ApplyDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Become a responder'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('responder-name'),
            controller: _name,
            autofocus: true,
            maxLength: 40,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'First name people will see',
            ),
          ),
          const Text(
            'You verify your identity once with an ID photo and a selfie (the ID itself is never saved). '
            'People you help see this name and your live location only while you go to them.',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            if (name.isNotEmpty) Navigator.pop(context, name);
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
