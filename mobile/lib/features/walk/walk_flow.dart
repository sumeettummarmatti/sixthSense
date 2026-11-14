import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/api/device_identity.dart';
import '../../core/location/live_location.dart';
import '../face_scan/face_scan_screen.dart';
import '../feedback/feedback_sheet.dart';
import '../profile/profile_screen.dart';
import '../verification/verification_flow.dart';

/// Where I roughly am, as (latitude, longitude); null when location is off.
typedef Locate = Future<(double, double)?> Function();

/// Walk With Me (P3-W3): a traveller on a journey asks a verified companion
/// nearby to walk with them; a companion goes available and accepts requests.
///
/// Companions verify their identity once (ID + selfie, the same verification
/// as responders) and can then be found straight away: there is no approval
/// step. Every accept needs a fresh face scan, checked by the server in the
/// same request, before any location is shared.
///
/// Privacy: a traveller sees only companions who chose to be available; a
/// companion sees a traveller's first name and rough area only after being
/// asked, and their profile only after accepting. Live location goes end to
/// end encrypted between the two walkers only (session id = walk id). The
/// traveller's journey check-ins and SOS keep running the whole time.
class WalkFlow extends StatefulWidget {
  const WalkFlow({
    super.key,
    required this.api,
    this.relay,
    this.journeyId,
    this.locate,
    this.pollInterval = const Duration(seconds: 3),
    this.presenceInterval = const Duration(minutes: 1),
    this.faceScanCamera,
    this.verifyIdentity,
  });

  final DemoApi api;

  /// Live location relay; when null (tests) no location is shared.
  final LiveLocationRelay? relay;

  /// The traveller's open journey. Asking for a companion needs one.
  final String? journeyId;
  final Locate? locate;
  final Duration pollInterval;
  final Duration presenceInterval;

  /// Front camera + on-device face count for the accept scan (tests inject one).
  final FaceScanCamera? faceScanCamera;

  /// Opens identity verification and returns whether it passed (tests inject
  /// one; the app opens the ID + selfie verification flow).
  final Future<bool> Function(BuildContext context)? verifyIdentity;

  @override
  State<WalkFlow> createState() => _WalkFlowState();
}

enum _Stage { loading, role, traveller, companion, walk }

class _WalkFlowState extends State<WalkFlow> {
  static const _privacyChannel = MethodChannel('in.sixthsense/privacy');

  var _stage = _Stage.loading;
  WalkView? _walk;
  Timer? _walkPoll;
  bool _feedbackAsked = false;
  String? _error;

  // Traveller
  bool _womenOnly = false;
  bool _searching = false;
  List<CompanionCard>? _companions;

  // Companion
  CompanionMe? _me;
  Profile? _profile;
  bool _joining = false;
  bool _available = false;
  Timer? _presence;
  Timer? _requestPoll;
  List<WalkRequestView> _requests = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_setScreenshotProtection(true));
    unawaited(_resume());
  }

  @override
  void dispose() {
    _walkPoll?.cancel();
    _presence?.cancel();
    _requestPoll?.cancel();
    unawaited(_setScreenshotProtection(false));
    super.dispose();
  }

  Future<void> _setScreenshotProtection(bool enabled) async {
    try {
      await _privacyChannel.invokeMethod<void>('setScreenshotProtection', {
        'enabled': enabled,
      });
    } on MissingPluginException {
      // The iOS privacy module is part of the later iOS port.
    } on PlatformException {
      // The flow remains usable if the OS does not support the protection.
    }
  }

  Future<void> _resume() async {
    try {
      final walk = await widget.api.currentWalk();
      if (!mounted) return;
      if (walk != null) return _showWalk(walk);
    } catch (_) {
      // Offline: still let the person choose a role.
    }
    if (mounted) setState(() => _stage = _Stage.role);
  }

  Future<(double, double)?> _whereAmI() async {
    if (widget.locate != null) return widget.locate!();
    final known = widget.relay?.myPosition.value;
    if (known != null) return (known.latitude, known.longitude);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission != LocationPermission.always &&
          permission != LocationPermission.whileInUse) {
        return null;
      }
      final here = await Geolocator.getCurrentPosition();
      return (here.latitude, here.longitude);
    } catch (_) {
      return null;
    }
  }

  void _say(String message) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ---- traveller -------------------------------------------------------------

  Future<void> _search() async {
    final journeyId = widget.journeyId;
    if (journeyId == null) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final here = await _whereAmI();
      if (here == null) {
        setState(() => _error = 'Turn on location to find companions nearby.');
        return;
      }
      final found = await widget.api.searchCompanions(
        journeyId: journeyId,
        lat: here.$1,
        lng: here.$2,
        womenOnly: _womenOnly,
      );
      if (mounted) setState(() => _companions = found);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = _explain(error.detail));
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not reach SixthSense.');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _ask(CompanionCard card) async {
    final journeyId = widget.journeyId;
    if (journeyId == null) return;
    final here = await _whereAmI();
    if (here == null) {
      _say('Turn on location to ask a companion.');
      return;
    }
    try {
      final walk = await widget.api.askCompanion(
        journeyId: journeyId,
        companionId: card.companionId,
        lat: here.$1,
        lng: here.$2,
      );
      if (mounted) _showWalk(walk);
    } on ApiException catch (error) {
      _say(_explain(error.detail));
      if (error.detail == 'companion_unavailable') unawaited(_search());
    } catch (_) {
      _say('Could not reach SixthSense.');
    }
  }

  // ---- companion -------------------------------------------------------------

  Future<void> _openCompanion() async {
    setState(() {
      _stage = _Stage.companion;
      _error = null;
    });
    try {
      final results = await Future.wait<Object?>([
        widget.api.companionMe(),
        widget.api.profile(),
      ]);
      if (!mounted) return;
      setState(() {
        _me = results[0] as CompanionMe;
        _profile = results[1] as Profile?;
        _available = _me!.available;
      });
      if (_me!.approved) _startRequestPoll();
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = _explain(error.detail));
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not reach SixthSense.');
    }
  }

  /// Join as a companion: verify identity first if needed (ID + selfie, done
  /// once), then join. No approval step.
  Future<void> _join() async {
    setState(() => _joining = true);
    try {
      if (!(_me?.identityVerified ?? false)) {
        final verified = await (widget.verifyIdentity ?? _openVerification)(
          context,
        );
        if (!mounted) return;
        if (!verified) {
          final me = await widget.api.companionMe();
          if (!mounted) return;
          setState(() => _me = me);
          if (!me.identityVerified) return;
        }
      }
      final me = await widget.api.joinAsCompanion();
      if (!mounted) return;
      setState(() => _me = me);
      if (me.approved) _startRequestPoll();
    } on ApiException catch (error) {
      _say(_explain(error.detail));
    } catch (_) {
      _say('Could not reach SixthSense.');
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  Future<bool> _openVerification(BuildContext context) async =>
      await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => VerificationFlowScreen(api: widget.api),
        ),
      ) ??
      false;

  Future<void> _setAvailable(bool on) async {
    if (!on) {
      _presence?.cancel();
      setState(() => _available = false);
      try {
        await widget.api.goUnavailable();
      } catch (_) {
        // The server forgets availability after 5 minutes anyway.
      }
      return;
    }
    if (!await _sendPresence()) return;
    setState(() => _available = true);
    _presence?.cancel();
    _presence = Timer.periodic(widget.presenceInterval, (_) => _sendPresence());
  }

  Future<bool> _sendPresence() async {
    final here = await _whereAmI();
    if (here == null) {
      _say('Turn on location to be available.');
      return false;
    }
    try {
      await widget.api.sendCompanionPresence(here.$1, here.$2);
      return true;
    } on ApiException catch (error) {
      _say(_explain(error.detail));
      return false;
    } catch (_) {
      return false;
    }
  }

  void _startRequestPoll() {
    _requestPoll?.cancel();
    unawaited(_loadRequests());
    _requestPoll = Timer.periodic(widget.pollInterval, (_) => _loadRequests());
  }

  Future<void> _loadRequests() async {
    try {
      final requests = await widget.api.walkRequests();
      if (!mounted) return;
      final same =
          requests.length == _requests.length &&
          [
            for (var i = 0; i < requests.length; i++)
              requests[i].id == _requests[i].id &&
                  requests[i].distanceMeters == _requests[i].distanceMeters,
          ].every((match) => match);
      if (!same) setState(() => _requests = requests);
    } catch (_) {
      // Keep the last list; the next poll tries again.
    }
  }

  /// Accept with a fresh face scan: the server checks it in the same request
  /// and only then shares the traveller's location.
  Future<void> _accept(WalkRequestView request) async {
    WalkView? accepted;
    String? problem;
    await FaceScanScreen.open(
      context,
      title: 'Accept walk',
      reason:
          "Before you see ${request.travellerFirstName}'s location, confirm "
          'that you, the verified companion, are holding this phone.',
      actionLabel: 'accept the walk and start sharing live location',
      camera: widget.faceScanCamera,
      submit: (scan) async {
        try {
          accepted = await widget.api.acceptWalk(request.id, scan: scan);
          return null;
        } on ApiException catch (error) {
          final faceProblem = faceScanProblem(error);
          if (faceProblem != null) return faceProblem; // retry on this screen
          problem = _explain(error.detail);
          return null; // close the scan: the request itself is gone
        }
      },
    );
    if (!mounted) return;
    final walk = accepted;
    if (walk != null) {
      _requestPoll?.cancel();
      _showWalk(walk);
    } else if (problem != null) {
      _say(problem!);
      unawaited(_loadRequests());
    }
  }

  Future<void> _decline(WalkRequestView request) async {
    try {
      await widget.api.declineWalk(request.id);
    } catch (_) {
      // It expires by itself after 10 minutes.
    }
    unawaited(_loadRequests());
  }

  // ---- the walk (both sides) -------------------------------------------------

  void _showWalk(WalkView walk) {
    setState(() {
      _walk = walk;
      _stage = _Stage.walk;
    });
    _syncSharing(walk);
    _walkPoll?.cancel();
    if (walk.open) {
      _walkPoll = Timer.periodic(widget.pollInterval, (_) => _refreshWalk());
    } else {
      unawaited(_afterWalk(walk));
    }
  }

  Future<void> _refreshWalk() async {
    final current = _walk;
    if (current == null) return;
    try {
      final walk = await widget.api.walk(current.id);
      if (!mounted) return;
      // Rebuild only when something visible changed (polls must not pile up
      // frames on slower phones).
      if (walk.status != current.status ||
          walk.handshakeCode != current.handshakeCode ||
          walk.partnerKeys.length != current.partnerKeys.length) {
        setState(() => _walk = walk);
      }
      _syncSharing(walk);
      if (!walk.open) {
        _walkPoll?.cancel();
        unawaited(_afterWalk(walk));
      }
    } catch (_) {
      // Keep showing the last state; the next poll tries again.
    }
  }

  /// Share my location with my walk partner only, while the walk is accepted.
  void _syncSharing(WalkView walk) {
    final relay = widget.relay;
    if (relay == null) return;
    if (walk.accepted && walk.partnerKeys.isNotEmpty) {
      if (!relay.isHelping(walk.id)) {
        unawaited(
          relay.startHelping(
            widget.api,
            OwnerKeys(journeyId: walk.id, keys: walk.partnerKeys),
          ),
        );
      }
    } else {
      unawaited(relay.stopHelping(walk.id));
    }
  }

  Future<void> _afterWalk(WalkView walk) async {
    if (_feedbackAsked || walk.status != 'ended' || !walk.isTraveller) return;
    final journeyId = walk.journeyId ?? widget.journeyId;
    if (journeyId == null) return;
    _feedbackAsked = true;
    await showFeedbackSheet(
      context,
      api: widget.api,
      journeyId: journeyId,
      walkId: walk.id,
      companionName: walk.partner?.firstName,
    );
  }

  Future<void> _endWalk() async {
    final walk = _walk;
    if (walk == null) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End the walk?'),
        content: Text(
          walk.isTraveller
              ? 'Location sharing with your companion stops. Your journey, check-ins and SOS keep running.'
              : 'Location sharing stops for both of you.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep walking'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('End walk'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    try {
      _showWalk(await widget.api.endWalk(walk.id));
    } on ApiException catch (error) {
      _say(_explain(error.detail));
      unawaited(_refreshWalk());
    } catch (_) {
      _say('Could not reach SixthSense.');
    }
  }

  Future<void> _cancelRequest() async {
    final walk = _walk;
    if (walk == null) return;
    try {
      await widget.api.cancelWalk(walk.id);
    } catch (_) {
      // It expires by itself after 10 minutes.
    }
    _walkPoll?.cancel();
    if (mounted) {
      setState(() {
        _walk = null;
        _stage = _Stage.traveller;
      });
    }
  }

  String _explain(String detail) => switch (detail) {
    'no_open_journey' => 'Start a journey first, then ask for a companion.',
    'companion_unavailable' =>
      'That companion is no longer available. The list was refreshed.',
    'walk_already_open' => 'You already have a walk request open.',
    'no_profile' => 'Add your first name in the Profile tab first.',
    'profile_not_willing' =>
      'Turn on "Willing to be a companion" in your Profile first.',
    'not_eligible' ||
    'identity_not_verified' => 'Verify your identity to walk as a companion.',
    'companion_revoked' => 'Your companion access was removed.',
    'walk_expired' => 'That request expired.',
    'already_walking' => 'You are already on a walk.',
    'server_unreachable' || 'server_timeout' => 'Could not reach SixthSense.',
    _ => 'Something went wrong ($detail).',
  };

  // ---- UI --------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Walk With Me'),
        leading: _stage == _Stage.traveller || _stage == _Stage.companion
            ? BackButton(
                onPressed: () {
                  _requestPoll?.cancel();
                  setState(() {
                    _stage = _Stage.role;
                    _error = null;
                  });
                },
              )
            : null,
      ),
      body: SafeArea(
        child: switch (_stage) {
          _Stage.loading => const Center(child: CircularProgressIndicator()),
          _Stage.role => _role(context),
          _Stage.traveller => _traveller(context),
          _Stage.companion => _companion(context),
          _Stage.walk => _walkView(context),
        },
      ),
    );
  }

  Widget _role(BuildContext context) {
    final theme = Theme.of(context);
    final canAsk = widget.journeyId != null;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Walk with someone', style: theme.textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(
          'Verified companions walk with you to a public place. You both see '
          'the same 4-digit code when you meet. Your check-ins and SOS keep '
          'working the whole time.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          key: const ValueKey('walk-traveller-role'),
          onPressed: canAsk
              ? () {
                  setState(() => _stage = _Stage.traveller);
                  unawaited(_search());
                }
              : null,
          icon: const Icon(Icons.directions_walk_rounded),
          label: const Text('Continue as traveller'),
        ),
        if (!canAsk)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Start a journey first to ask for a companion.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const ValueKey('walk-companion-role'),
          onPressed: _openCompanion,
          icon: const Icon(Icons.volunteer_activism_outlined),
          label: const Text('Continue as companion'),
        ),
      ],
    );
  }

  Widget _traveller(BuildContext context) {
    final theme = Theme.of(context);
    final companions = _companions;
    return RefreshIndicator(
      onRefresh: _search,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Companions nearby', style: theme.textTheme.headlineSmall),
          CheckboxListTile(
            key: const ValueKey('walk-women-only'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Women companions only'),
            value: _womenOnly,
            onChanged: (value) {
              setState(() => _womenOnly = value ?? false);
              unawaited(_search());
            },
          ),
          if (_searching) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(_error!),
            ),
          if (companions != null && companions.isEmpty && !_searching)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'No companions are available near you right now. Pull down '
                'to look again; your journey keeps running either way.',
              ),
            ),
          for (final card in companions ?? const <CompanionCard>[])
            _CompanionTile(card: card, onAsk: () => _ask(card)),
        ],
      ),
    );
  }

  Widget _companion(BuildContext context) {
    final theme = Theme.of(context);
    final me = _me;
    if (_error != null) return Center(child: Text(_error!));
    if (me == null) return const Center(child: CircularProgressIndicator());
    final willing = _profile?.willingCompanion ?? false;
    final children = <Widget>[];
    if (!willing) {
      children.addAll([
        Text('Become a companion', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
          'Add your first name and turn on "Willing to be a companion" in '
          'your profile first.',
        ),
        const SizedBox(height: 16),
        FilledButton(
          key: const ValueKey('walk-open-profile'),
          onPressed: () async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ProfileScreen(api: widget.api),
              ),
            );
            if (mounted) unawaited(_openCompanion());
          },
          child: const Text('Open my profile'),
        ),
      ]);
    } else if (me.status == 'none' || !me.identityVerified) {
      children.addAll([
        Text(
          me.identityVerified ? 'Join as a companion' : 'Verify your identity',
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Icon(
                  Icons.badge_outlined,
                  size: 48,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 8),
                Text(
                  me.identityVerified
                      ? 'Your identity is verified. Join to be found by '
                            'travellers nearby, straight away.'
                      : 'Companions verify once with an ID photo and a '
                            'selfie, the same check as responders. Then you '
                            'can be found straight away: no waiting for '
                            'approval. Each time you accept a walk you take a '
                            'quick face scan so travellers know it is you.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                if (_joining)
                  const LinearProgressIndicator()
                else
                  FilledButton.icon(
                    key: const ValueKey('walk-join'),
                    onPressed: _join,
                    icon: Icon(
                      me.identityVerified
                          ? Icons.how_to_reg_outlined
                          : Icons.camera_alt_outlined,
                    ),
                    label: Text(
                      me.identityVerified
                          ? 'Join as companion'
                          : 'Verify and join',
                    ),
                  ),
              ],
            ),
          ),
        ),
      ]);
    } else if (me.status == 'revoked') {
      children.add(const Text('Your companion access was removed.'));
    } else {
      children.addAll([
        const Chip(
          avatar: Icon(Icons.verified_outlined, size: 18),
          label: Text('Verified companion'),
        ),
        SwitchListTile(
          key: const ValueKey('walk-available'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Available to walk'),
          subtitle: const Text(
            'Travellers nearby see your first name, bio and strengths, and a '
            'rough distance. Never your exact location.',
          ),
          value: _available,
          onChanged: _setAvailable,
        ),
        const SizedBox(height: 8),
        Text('Requests', style: theme.textTheme.titleMedium),
        if (_requests.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('No requests right now.'),
          ),
        for (final request in _requests)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${request.travellerFirstName} asked to walk with you',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (request.distanceMeters != null)
                        '~${request.distanceMeters} m away',
                      'expires in ${_minutesLeft(request.expiresAt)} min',
                    ].join(' · '),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _decline(request),
                          child: const Text('Decline'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          key: ValueKey('walk-accept-${request.id}'),
                          onPressed: () => _accept(request),
                          child: const Text('Accept'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ]);
    }
    return ListView(padding: const EdgeInsets.all(20), children: children);
  }

  Widget _walkView(BuildContext context) {
    final theme = Theme.of(context);
    final walk = _walk!;
    final partner = walk.partner;
    final name = partner?.firstName ?? 'Your companion';
    final children = <Widget>[];
    switch (walk.status) {
      case 'requested':
        children.addAll([
          Text('Waiting for $name', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            'They have ${_minutesLeft(walk.expiresAt)} min to answer. Your '
            'journey keeps running meanwhile.',
          ),
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
          const SizedBox(height: 16),
          OutlinedButton(
            key: const ValueKey('walk-cancel'),
            onPressed: _cancelRequest,
            child: const Text('Cancel request'),
          ),
        ]);
      case 'accepted':
        children.addAll([
          Text(
            walk.isTraveller
                ? '$name is walking with you'
                : 'Walking with $name',
            style: theme.textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              walk.handshakeCode ?? '----',
              key: const ValueKey('walk-handshake-code'),
              style: theme.textTheme.displayMedium?.copyWith(
                letterSpacing: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'When you meet, check $name sees the same code. If it does not '
            'match, do not walk together.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.place_outlined),
            title: Text(
              walk.isTraveller
                  ? 'Meet near where you asked from'
                  : "Meet near $name's rough area",
            ),
            subtitle: const Text(
              'Within about 100 m. Pick a busy, public spot: a shop front, a '
              'gate or a bus stop.',
            ),
            trailing: walk.meetNear == null
                ? null
                : IconButton(
                    tooltip: 'Open in maps',
                    icon: const Icon(Icons.map_outlined),
                    onPressed: () => widget.api.identity.openUrl(
                      'geo:${walk.meetNear!.latitude},${walk.meetNear!.longitude}'
                      '?q=${walk.meetNear!.latitude},${walk.meetNear!.longitude}',
                    ),
                  ),
          ),
          if (widget.relay != null)
            _PartnerDistance(walk: walk, relay: widget.relay!),
          if (partner != null) _PartnerCard(partner: partner),
          const SizedBox(height: 8),
          if (walk.isTraveller)
            Text(
              'Your check-ins and SOS keep working. An SOS also alerts $name.',
              style: theme.textTheme.bodySmall,
            ),
          const SizedBox(height: 16),
          FilledButton.tonal(
            key: const ValueKey('walk-end'),
            onPressed: _endWalk,
            child: const Text('End walk'),
          ),
        ]);
      default:
        children.addAll([
          Text(_endTitle(walk, name), style: theme.textTheme.headlineSmall),
          const SizedBox(height: 16),
          if (walk.isTraveller && walk.status != 'ended')
            FilledButton(
              onPressed: () {
                setState(() {
                  _walk = null;
                  _stage = _Stage.traveller;
                });
                unawaited(_search());
              },
              child: const Text('Find another companion'),
            ),
          OutlinedButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Done'),
          ),
        ]);
    }
    return ListView(padding: const EdgeInsets.all(20), children: children);
  }

  static String _endTitle(WalkView walk, String name) => switch (walk.status) {
    'declined' => '$name could not walk this time',
    'expired' => '$name did not answer in time',
    'cancelled' => 'Request cancelled',
    _ => switch (walk.endReason) {
      'journey_over' => 'The journey ended, so the walk ended',
      _ => 'Walk ended',
    },
  };

  static int _minutesLeft(DateTime until) {
    final left = until.difference(DateTime.now()).inSeconds;
    return left <= 0 ? 0 : (left / 60).ceil();
  }
}

class _CompanionTile extends StatelessWidget {
  const _CompanionTile({required this.card, required this.onAsk});

  final CompanionCard card;
  final VoidCallback onAsk;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = card.profile;
    final rating = card.rating == null
        ? 'New companion'
        : '★ ${card.rating!.toStringAsFixed(1)} (${card.ratingCount})';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    profile.firstName,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Text(rating, style: theme.textTheme.bodySmall),
              ],
            ),
            Text(
              '~${card.distanceMeters} m away · ${card.walkMinutes} min walk',
              style: theme.textTheme.bodySmall,
            ),
            if (profile.bio.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(profile.bio),
            ],
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final strength in profile.strengths)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(profileStrengths[strength] ?? strength),
                  ),
                for (final language in profile.languages)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: const Icon(Icons.translate_rounded, size: 16),
                    label: Text(language),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                key: ValueKey('walk-ask-${card.companionId}'),
                onPressed: onAsk,
                child: const Text('Ask to walk with me'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PartnerCard extends StatelessWidget {
  const _PartnerCard({required this.partner});

  final PartnerProfile partner;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              partner.firstName,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (partner.bio.isNotEmpty) Text(partner.bio),
            Wrap(
              spacing: 6,
              children: [
                for (final strength in partner.strengths)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(profileStrengths[strength] ?? strength),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// How far my walk partner is, from their end-to-end encrypted live location.
class _PartnerDistance extends StatelessWidget {
  const _PartnerDistance({required this.walk, required this.relay});

  final WalkView walk;
  final LiveLocationRelay relay;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, ReceivedLocation>>(
      valueListenable: relay.received,
      builder: (context, received, _) => ValueListenableBuilder<Position?>(
        valueListenable: relay.myPosition,
        builder: (context, me, _) {
          final them = received[walk.id];
          final name = walk.partner?.firstName ?? 'Your companion';
          final text = them == null || me == null
              ? 'Waiting for $name\'s live location…'
              : '$name is ~${Geolocator.distanceBetween(me.latitude, me.longitude, them.latitude, them.longitude).round()} m away';
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.share_location_outlined),
            title: Text(text),
            subtitle: const Text(
              'Shared only between the two of you, end to end encrypted',
            ),
          );
        },
      ),
    );
  }
}
