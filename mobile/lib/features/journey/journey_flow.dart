import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:geolocator/geolocator.dart';

import '../../core/api/device_identity.dart';
import '../../core/contacts/contact_book.dart';
import '../../core/journey/journey_runtime.dart';
import '../../core/location/live_location.dart';
import '../../core/theme/app_theme.dart';
import '../contacts/contact_alerts.dart';
import '../contacts/contact_alerts_screen.dart';
import '../help/helpers_panel.dart';
import 'destination_picker.dart';
import '../walk/walk_flow.dart';
import '../map/map_route_screen.dart';

class JourneyFlow extends StatefulWidget {
  const JourneyFlow({
    super.key,
    this.now,
    this.runtime = const JourneyRuntime(),
    this.api = const DemoApi(),
    this.onDuressRequested,
    this.onCovertSosRequested,
    this.relay,
  });

  /// Shares live location with contacts during a journey; null turns it off (tests).
  final LiveLocationRelay? relay;
  final DateTime Function()? now;
  final JourneyRuntime runtime;
  final DemoApi api;
  final VoidCallback? onDuressRequested;
  final VoidCallback? onCovertSosRequested;

  @override
  State<JourneyFlow> createState() => _JourneyFlowState();
}

class _JourneyFlowState extends State<JourneyFlow> with WidgetsBindingObserver {
  JourneyPlan? _plan;
  DateTime? _nextCheckIn;
  Timer? _ticker;
  Timer? _heartbeatTicker;
  String? _serverJourneyId;
  var _promptReported = false;
  Duration _remaining = Duration.zero;
  bool _checkInDue = false;
  var _wrongPinAttempts = 0;
  late final DateTime Function() _now;

  // Who is coming to help (polled while a journey is open).
  final _help = ValueNotifier<HelpView>(HelpView.none);
  Timer? _helpPoll;
  final _knownHelpers = <String>{};
  Map<String, LocalContact> _names = const {};
  DateTime _lastAreaSent = DateTime.fromMillisecondsSinceEpoch(0);
  var _covertSos = false;

  @override
  void initState() {
    super.initState();
    _now = widget.now ?? DateTime.now;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _heartbeatTicker?.cancel();
    _helpPoll?.cancel();
    _help.dispose();
    super.dispose();
  }

  void _startHelpPolling(String journeyId) {
    _helpPoll?.cancel();
    _knownHelpers.clear();
    _help.value = HelpView.none;
    _lastAreaSent = DateTime.fromMillisecondsSinceEpoch(0);
    ContactBook(widget.api.identity)
        .load()
        .then((names) => _names = names, onError: (_) {});
    _helpPoll = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _pollHelp(journeyId),
    );
  }

  void _stopHelpPolling() {
    _helpPoll?.cancel();
    _helpPoll = null;
    _knownHelpers.clear();
    _help.value = HelpView.none;
    _covertSos = false;
  }

  Future<void> _pollHelp(String journeyId) async {
    HelpView view;
    try {
      view = await widget.api.help(journeyId);
    } catch (_) {
      return; // offline: the phone-side timers still protect the user
    }
    if (!mounted || _serverJourneyId != journeyId) return;
    _help.value = view;
    widget.relay?.setJourneyHelpers([
      for (final helper in view.helpers) ...helper.keys,
    ]);
    final fresh = view.helpers.where((h) => _knownHelpers.add(h.id)).toList();
    if (fresh.isNotEmpty && !_covertSos) {
      final first = fresh.first;
      final name = first.isResponder
          ? '${first.label ?? 'A verified responder'} (verified responder)'
          : _names[first.contactLinkId]?.name ?? 'Your contact';
      unawaited(HapticFeedback.heavyImpact());
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              fresh.length == 1
                  ? '$name is coming to you'
                  : '${fresh.length} people are coming to you',
            ),
          ),
        );
    }
    if (view.fullAlert) await _sendArea(journeyId);
  }

  /// Rough area for finding responders nearby, every 30 s during a full alert.
  Future<void> _sendArea(String journeyId, {bool now = false}) async {
    if (!now &&
        DateTime.now().difference(_lastAreaSent) <
            const Duration(seconds: 30)) {
      return;
    }
    var position = widget.relay?.myPosition.value;
    try {
      position ??= await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 8),
        ),
      );
      await widget.api.sendAlertArea(
        journeyId,
        position.latitude,
        position.longitude,
      );
      _lastAreaSent = DateTime.now();
    } catch (_) {
      // No GPS or offline: contacts are still alerted; retry on the next poll.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _plan != null) {
      _updateCountdown();
      _sendHeartbeat();
    }
  }

  Future<void> _startJourney(JourneyPlan plan) async {
    var nextCheckIn = _now().add(plan.checkInInterval);
    String? serverJourneyId;
    var heartbeatTimeoutMinutes = 10;
    String? serverWarning;
    try {
      final remote = await widget.api.startJourney(
        plan.checkInInterval.inMinutes,
      );
      serverJourneyId = remote.id;
      nextCheckIn = remote.nextCheckInAt;
      heartbeatTimeoutMinutes = remote.heartbeatTimeoutMinutes;
    } on ApiException catch (error) {
      serverWarning = error.detail;
    } catch (_) {
      serverWarning = 'server_unreachable';
    }
    try {
      await widget.runtime.startJourney(
        nextCheckIn: nextCheckIn,
        smsNumbers: plan.smsNumbers,
        smsFallbackEnabled: plan.smsFallbackEnabled,
      );
    } on PlatformException catch (error) {
      // The phone timer did not start, so don't leave a journey open on the server.
      if (serverJourneyId != null) {
        unawaited(
          widget.api.endJourney(serverJourneyId).then((_) {}, onError: (_) {}),
        );
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      final exactAlarmNeeded = error.code == 'exact_alarm_permission_required';
      final notificationNeeded =
          error.code == 'notification_permission_required';
      final smsPermissionsNeeded = error.code == 'sms_permissions_required';
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            exactAlarmNeeded
                ? 'Allow Alarms & reminders to start a reliable check-in timer.'
                : notificationNeeded
                ? 'Allow notifications, then tap Start journey again.'
                : smsPermissionsNeeded
                ? 'Allow SMS and location, then tap Start journey again to enable offline alerts.'
                : error.message ?? 'Could not start the journey timer.',
          ),
          action: exactAlarmNeeded
              ? SnackBarAction(
                  label: 'Open settings',
                  onPressed: widget.runtime.requestExactAlarmAccess,
                )
              : null,
        ),
      );
      return;
    }

    if (!mounted) return;
    _ticker?.cancel();
    setState(() {
      _plan = plan;
      _checkInDue = false;
      _promptReported = false;
      _serverJourneyId = serverJourneyId;
      _nextCheckIn = nextCheckIn;
      _remaining = nextCheckIn.difference(_now());
    });
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _updateCountdown(),
    );
    _heartbeatTicker?.cancel();
    if (serverJourneyId != null) {
      unawaited(widget.relay?.startSharing(widget.api, serverJourneyId));
      if (widget.relay != null) _startHelpPolling(serverJourneyId);
      final heartbeatMinutes = (heartbeatTimeoutMinutes ~/ 2).clamp(1, 60);
      _heartbeatTicker = Timer.periodic(
        Duration(minutes: heartbeatMinutes),
        (_) => _sendHeartbeat(),
      );
    }
    if (serverWarning != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Server unavailable. The local timer and opted-in SMS fallback are active; contact alerts are not connected.',
          ),
        ),
      );
    }
  }

  void _updateCountdown() {
    final deadline = _nextCheckIn;
    if (deadline == null || !mounted) return;
    final remaining = deadline.difference(_now());
    if (remaining <= Duration.zero) {
      _ticker?.cancel();
      setState(() {
        _remaining = Duration.zero;
        _checkInDue = true;
      });
      _reportPromptShown();
      return;
    }
    setState(() => _remaining = remaining);
  }

  Future<void> _checkIn({bool duress = false}) async {
    final plan = _plan;
    if (plan == null) return;
    var nextCheckIn = _now().add(plan.checkInInterval);
    final journeyId = _serverJourneyId;
    if (journeyId != null) {
      try {
        final remote = await widget.api.checkIn(journeyId, duress: duress);
        nextCheckIn = remote.nextCheckInAt;
      } on ApiException catch (error) {
        if (error.detail == 'journey_over') {
          await _journeyEndedOnServer();
          return;
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Check-in saved locally; server update failed (${error.detail}).',
              ),
            ),
          );
        }
      }
    }
    try {
      await widget.runtime.checkIn(
        nextCheckIn: nextCheckIn,
        smsNumbers: plan.smsNumbers,
        smsFallbackEnabled: plan.smsFallbackEnabled,
      );
    } on PlatformException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.message ?? 'Could not reset the check-in timer.'),
        ),
      );
      return;
    }
    if (!mounted) return;
    setState(() {
      _checkInDue = false;
      _promptReported = false;
      _nextCheckIn = nextCheckIn;
      _remaining = nextCheckIn.difference(_now());
    });
    _ticker?.cancel();
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _updateCountdown(),
    );
  }

  Future<void> _enterCheckInPin() async {
    final plan = _plan;
    if (plan == null) return;
    final pin = await showDialog<String>(
      context: context,
      builder: (_) => const _CheckInPinDialog(),
    );
    if (!mounted || pin == null) return;
    if (pin == plan.duressPin) {
      _wrongPinAttempts = 0;
      await _requestDuress();
      await _checkIn(duress: true);
    } else if (pin == plan.realPin) {
      _wrongPinAttempts = 0;
      await _checkIn(duress: false);
    } else {
      _wrongPinAttempts++;
      if (_wrongPinAttempts >= 3) {
        _wrongPinAttempts = 0;
        await _requestDuress();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That PIN did not match. Try again.')),
      );
    }
  }

  Future<void> _requestDuress() async {
    widget.onDuressRequested?.call();
    try {
      await widget.runtime.requestDuress();
    } on PlatformException {
      // Keep coercion feedback discreet if the optional SMS path is unavailable.
    }
  }

  Future<void> _requestSos(bool covert) async {
    String? serverError;
    final journeyId = _serverJourneyId;
    if (journeyId == null) {
      serverError = 'no_server_journey';
    } else {
      try {
        await widget.api.requestSos(journeyId, covert: covert);
        _covertSos = covert;
        if (widget.relay != null) {
          unawaited(
            _sendArea(journeyId, now: true).then((_) => _pollHelp(journeyId)),
          );
        }
      } on ApiException catch (error) {
        serverError = error.detail;
      } catch (_) {
        serverError = 'server_unreachable';
      }
    }
    if (covert) {
      await widget.runtime.requestCovertSos();
      widget.onCovertSosRequested?.call();
      await HapticFeedback.heavyImpact();
      if (serverError != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Covert SOS could not reach the server; local safety actions remain active.',
            ),
          ),
        );
      }
      return;
    }
    final smsSubmitted = await widget.runtime.requestSos();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('SOS requested'),
        content: Text(
          serverError != null
              ? 'The server could not be reached ($serverError). ${smsSubmitted ? 'A safety SMS was submitted to Android for sending.' : 'Offline SMS works only during an opted-in journey when internet is unavailable.'} If you need emergency help, call 112 from your phone.'
              : smsSubmitted
              ? 'The SOS was sent to the server and a safety SMS was submitted to Android for sending. If you need emergency help, call 112 from your phone.'
              : 'The SOS was sent to the server. No SMS was sent; offline SMS works only during an opted-in journey when internet is unavailable. If you need emergency help, call 112 from your phone.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _endJourney() async {
    final shouldEnd = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End this journey?'),
        content: const Text('The on-device check-in timer will stop.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep going'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('End journey'),
          ),
        ],
      ),
    );
    if (shouldEnd == true && mounted) {
      String? serverError;
      final journeyId = _serverJourneyId;
      if (journeyId != null) {
        try {
          await widget.api.endJourney(journeyId);
        } on ApiException catch (error) {
          serverError = error.detail;
        } catch (_) {
          serverError = 'server_unreachable';
        }
      }
      try {
        await widget.runtime.endJourney();
      } on PlatformException catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.message ?? 'Could not stop the journey timer.'),
          ),
        );
        return;
      }
      if (!mounted) return;
      _ticker?.cancel();
      _heartbeatTicker?.cancel();
      _stopHelpPolling();
      unawaited(widget.relay?.stopSharing());
      setState(() {
        _plan = null;
        _serverJourneyId = null;
        _nextCheckIn = null;
        _remaining = Duration.zero;
        _checkInDue = false;
      });
      if (serverError != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Journey ended on this phone; server update failed ($serverError).',
            ),
          ),
        );
      }
    }
  }

  /// A contact confirmed the user is OK after a full alert, which ends the
  /// journey on the server. Stop the phone timer too and say why.
  Future<void> _journeyEndedOnServer() async {
    try {
      await widget.runtime.endJourney();
    } on PlatformException {
      // Still clear the screen; the timer only re-alerts for an active journey.
    }
    if (!mounted) return;
    _ticker?.cancel();
    _heartbeatTicker?.cancel();
    _stopHelpPolling();
    unawaited(widget.relay?.stopSharing());
    setState(() {
      _plan = null;
      _serverJourneyId = null;
      _nextCheckIn = null;
      _remaining = Duration.zero;
      _checkInDue = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Your contact confirmed you are OK, so this journey has ended. Start a new one any time.',
        ),
      ),
    );
  }

  Future<void> _reportPromptShown() async {
    final journeyId = _serverJourneyId;
    if (journeyId == null || _promptReported) return;
    _promptReported = true;
    try {
      await widget.api.promptShown(journeyId);
    } on ApiException {
      // The local prompt must still work if the network is unavailable.
    }
  }

  Future<void> _sendHeartbeat() async {
    final journeyId = _serverJourneyId;
    if (journeyId == null) return;
    try {
      await widget.api.heartbeat(journeyId);
    } on ApiException catch (error) {
      if (error.detail == 'journey_over') {
        await _journeyEndedOnServer();
        return;
      }
      // A missed heartbeat is detected by the server watchdog; local timers remain active.
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    if (plan == null) {
      return JourneySetupScreen(onStart: _startJourney, api: widget.api);
    }
    // Rebuild when helpers change so the timer can shrink to make room.
    return ValueListenableBuilder<HelpView>(
      valueListenable: _help,
      builder: (context, _, _) => _activeScreen(plan),
    );
  }

  Widget _activeScreen(JourneyPlan plan) {
    return ActiveJourneyScreen(
      plan: plan,
      remaining: _remaining,
      isCheckInDue: _checkInDue,
      onCheckIn: _enterCheckInPin,
      onEnd: _endJourney,
      onSos: _requestSos,
      onRequestBatteryExemption: _requestBatteryExemption,
      api: widget.api,
      sharing: widget.relay?.sharing,
      helpersPanel: widget.relay == null || _serverJourneyId == null
          ? null
          : ValueListenableBuilder<HelpView>(
              valueListenable: _help,
              builder: (context, view, _) => _covertSos
                  ? const SizedBox.shrink() // a silent alarm shows nothing new
                  : HelpersPanel(
                      help: _help,
                      relay: widget.relay!,
                      names: _names,
                    ),
            ),
      compact: _help,
    );
  }

  Future<void> _requestBatteryExemption() async {
    try {
      await widget.runtime.requestBatteryExemption();
    } on PlatformException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.message ?? 'Could not open battery settings.'),
        ),
      );
    }
  }
}

@immutable
class JourneyPlan {
  const JourneyPlan({
    required this.destination,
    required this.checkInInterval,
    required this.realPin,
    required this.duressPin,
    this.smsNumbers = const [],
    this.smsFallbackEnabled = false,
    this.destinationLatitude,
    this.destinationLongitude,
  });

  final String destination;

  /// Picked on the map; kept on this phone only (never sent to the server).
  final double? destinationLatitude;
  final double? destinationLongitude;
  final Duration checkInInterval;
  final String realPin;
  final String duressPin;
  final List<String> smsNumbers;
  final bool smsFallbackEnabled;
}

class JourneySetupScreen extends StatefulWidget {
  const JourneySetupScreen({
    super.key,
    required this.onStart,
    this.api = const DemoApi(),
  });

  final ValueChanged<JourneyPlan> onStart;
  final DemoApi api;

  @override
  State<JourneySetupScreen> createState() => _JourneySetupScreenState();
}

class _JourneySetupScreenState extends State<JourneySetupScreen> {
  final _destinationController = TextEditingController();
  final _realPinController = TextEditingController();
  final _duressPinController = TextEditingController();
  final _smsNumberController = TextEditingController();
  var _selectedMinutes = 5;
  var _smsFallbackEnabled = false;
  Destination? _destination;
  int? _suggestedFor;

  void _onDestination(Destination destination, int? walkMinutes) {
    _destination = destination;
    if (walkMinutes == null) {
      if (_suggestedFor != null) setState(() => _suggestedFor = null);
      return;
    }
    // Short walks: check in often. Long ones: less nagging.
    final suggested = walkMinutes <= 15
        ? 5
        : walkMinutes <= 40
        ? 10
        : 15;
    setState(() {
      _suggestedFor = walkMinutes;
      _selectedMinutes = suggested;
    });
  }

  static const _intervals = [1, 5, 10, 15];

  @override
  void dispose() {
    _destinationController.dispose();
    _realPinController.dispose();
    _duressPinController.dispose();
    _smsNumberController.dispose();
    super.dispose();
  }

  void _start() {
    final destination = _destinationController.text.trim();
    if (destination.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Add a destination to plan your journey.'),
        ),
      );
      return;
    }
    final realPin = _realPinController.text.trim();
    final duressPin = _duressPinController.text.trim();
    if (!RegExp(r'^\d{4}$').hasMatch(realPin) ||
        !RegExp(r'^\d{4}$').hasMatch(duressPin)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Set both PINs to four digits.')),
      );
      return;
    }
    if (realPin == duressPin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose two different PINs.')),
      );
      return;
    }
    final smsNumber = _smsNumberController.text.trim().replaceAll(' ', '');
    if (_smsFallbackEnabled &&
        !RegExp(r'^\+?[0-9]{10,15}$').hasMatch(smsNumber)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid SMS contact number.')),
      );
      return;
    }
    widget.onStart(
      JourneyPlan(
        destination: destination,
        destinationLatitude: _destination?.latitude,
        destinationLongitude: _destination?.longitude,
        checkInInterval: Duration(minutes: _selectedMinutes),
        realPin: realPin,
        duressPin: duressPin,
        smsNumbers: _smsFallbackEnabled ? [smsNumber] : const [],
        smsFallbackEnabled: _smsFallbackEnabled,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final text = theme.textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Plan a journey'),
        actions: [
          IconButton(
            tooltip: 'Accept an invite',
            onPressed: () => acceptInviteFlow(context, widget.api),
            icon: const Icon(Icons.link_rounded),
          ),
          IconButton(
            tooltip: 'People you support',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ContactAlertsScreen(api: widget.api),
              ),
            ),
            icon: const Icon(Icons.volunteer_activism_outlined),
          ),
          IconButton(
            tooltip: 'Get alerts on Telegram',
            onPressed: () => linkTelegramFlow(context, widget.api),
            icon: const Icon(Icons.notifications_active_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
              children: [
                ContactAlertBanner(api: widget.api),
                Text(
                  'A little check-in goes a long way.',
                  style: text.headlineMedium,
                ),
                const SizedBox(height: 10),
                Text(
                  'Set where you’re headed and when you’d like the app to check in with you.',
                  style: text.bodyLarge?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 28),
                Text('Where are you going?', style: text.titleSmall),
                const SizedBox(height: 8),
                DestinationPicker(
                  controller: _destinationController,
                  onChanged: _onDestination,
                ),
                const SizedBox(height: 28),
                Text('Check in every', style: text.titleSmall),
                if (_suggestedFor != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Suggested for a ~$_suggestedFor min walk',
                    style: text.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final minutes in _intervals)
                      ChoiceChip(
                        label: Text('$minutes min'),
                        selected: _selectedMinutes == minutes,
                        onSelected: (_) =>
                            setState(() => _selectedMinutes = minutes),
                      ),
                  ],
                ),
                const SizedBox(height: 26),
                Text('Set your check-in PINs', style: text.titleSmall),
                const SizedBox(height: 8),
                Text(
                  'Use your usual PIN to check in. Choose a different duress PIN that looks the same when entered.',
                  style: text.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('journey-real-pin'),
                  controller: _realPinController,
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  maxLength: 4,
                  decoration: const InputDecoration(
                    labelText: 'Check-in PIN',
                    border: OutlineInputBorder(),
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey('journey-duress-pin'),
                  controller: _duressPinController,
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  maxLength: 4,
                  decoration: const InputDecoration(
                    labelText: 'Duress PIN',
                    border: OutlineInputBorder(),
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 18),
                SwitchListTile.adaptive(
                  key: const ValueKey('sms-fallback-switch'),
                  contentPadding: EdgeInsets.zero,
                  value: _smsFallbackEnabled,
                  onChanged: (enabled) =>
                      setState(() => _smsFallbackEnabled = enabled),
                  title: const Text('Enable offline SMS fallback'),
                  subtitle: const Text(
                    'With your permission, safety alerts can text one contact if internet is unavailable. At 10% battery or lower, alerts use SMS. Carrier SMS charges may apply.',
                  ),
                ),
                if (_smsFallbackEnabled) ...[
                  const SizedBox(height: 8),
                  TextField(
                    key: const ValueKey('journey-sms-contact'),
                    controller: _smsNumberController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Trusted contact phone',
                      hintText: '+91 98765 43210',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: colors.outline),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.shield_outlined, color: colors.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Journey PINs stay in memory only. SMS fallback is optional and requires SMS/location permission; only one journey contact is stored encrypted on this phone until the journey ends. Android timers use an ongoing notification and exact alarm.',
                          style: text.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 26),
                FilledButton.icon(
                  onPressed: _start,
                  icon: const Icon(Icons.route_rounded),
                  label: const Text('Start journey'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ActiveJourneyScreen extends StatelessWidget {
  const ActiveJourneyScreen({
    super.key,
    required this.plan,
    required this.remaining,
    required this.isCheckInDue,
    required this.onCheckIn,
    required this.onEnd,
    required this.onSos,
    required this.onRequestBatteryExemption,
    this.api = const DemoApi(),
    this.sharing,
    this.helpersPanel,
    this.compact,
  });

  /// Who is coming to help, while an alert is open.
  final Widget? helpersPanel;

  /// When an alert is open the timer shrinks to make room for helpers.
  final ValueListenable<HelpView>? compact;

  /// Live location sharing status, if sharing is on.
  final ValueListenable<SharingStatus>? sharing;
  final JourneyPlan plan;
  final Duration remaining;
  final bool isCheckInDue;
  final VoidCallback onCheckIn;
  final VoidCallback onEnd;
  final ValueChanged<bool> onSos;
  final VoidCallback onRequestBatteryExemption;
  final DemoApi api;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final text = theme.textTheme;
    final intervalSeconds = plan.checkInInterval.inSeconds;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final alertOpen =
        compact != null &&
        (compact!.value.anyAlert || compact!.value.helpers.isNotEmpty);
    final timerDiameter = alertOpen
        ? 120.0
        : screenHeight < 700
        ? 184.0
        : 224.0;
    final progress = intervalSeconds == 0
        ? 0.0
        : (remaining.inSeconds / intervalSeconds).clamp(0.0, 1.0);
    final durationText =
        '${remaining.inMinutes.toString().padLeft(2, '0')}:'
        '${(remaining.inSeconds % 60).toString().padLeft(2, '0')}';

    return Scaffold(
      appBar: AppBar(
        leading: Semantics(
          button: true,
          label: 'SixthSense',
          onLongPress: () => onSos(true),
          child: GestureDetector(
            onLongPress: () => onSos(true),
            child: const Center(child: Icon(Icons.wb_twilight_rounded)),
          ),
        ),
        title: const Text('Journey in progress'),
        actions: [
          IconButton(
            tooltip: 'Map and route preview',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => MapRouteScreen(destination: plan.destination),
              ),
            ),
            icon: const Icon(Icons.map_outlined),
          ),
          IconButton(
            tooltip: 'Walk With Me',
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => WalkFlow(api: api))),
            icon: const Icon(Icons.directions_walk_rounded),
          ),
          IconButton(
            tooltip: 'Battery settings',
            onPressed: onRequestBatteryExemption,
            icon: const Icon(Icons.battery_saver_outlined),
          ),
          IconButton(
            tooltip: 'End journey',
            onPressed: onEnd,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
              // During an alert the helpers panel makes this taller than the
              // screen, so it scrolls; otherwise it fills the screen.
              child: _ScrollWhen(
                scroll: alertOpen,
                children: [
                  const SizedBox(height: 12),
                  Text(
                    'ON YOUR WAY TO',
                    style: text.labelMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    plan.destination,
                    style: text.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  if (sharing != null) ...[
                    const SizedBox(height: 12),
                    ValueListenableBuilder<SharingStatus>(
                      valueListenable: sharing!,
                      builder: (context, status, _) =>
                          _SharingChip(status: status),
                    ),
                  ],
                  if (helpersPanel != null) ...[
                    const SizedBox(height: 12),
                    helpersPanel!,
                  ],
                  _Gap(scroll: alertOpen),
                  SizedBox(
                    width: timerDiameter,
                    height: timerDiameter,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox.expand(
                          child: CircularProgressIndicator(
                            value: isCheckInDue ? 0 : progress,
                            strokeWidth: 12,
                            strokeCap: StrokeCap.round,
                            backgroundColor: colors.primaryContainer,
                          ),
                        ),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isCheckInDue
                                    ? Icons.notifications_active_outlined
                                    : Icons.schedule_rounded,
                                color: isCheckInDue
                                    ? AppColors.caution
                                    : colors.primary,
                                size: 30,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                isCheckInDue ? 'Check in now' : durationText,
                                style: isCheckInDue
                                    ? text.titleLarge
                                    : text.displaySmall,
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                isCheckInDue
                                    ? 'Your check-in is due'
                                    : 'until your next check-in',
                                style: text.bodySmall?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  _Gap(scroll: alertOpen),
                  if (isCheckInDue)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 14),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppColors.caution),
                      ),
                      child: Text(
                        'Check in soon, or your contacts get an alert.',
                        style: text.bodyMedium?.copyWith(
                          color: AppColors.caution,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  FilledButton.icon(
                    onPressed: onCheckIn,
                    icon: const Icon(Icons.check_circle_outline_rounded),
                    label: const Text('Check in'),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: colors.error,
                      foregroundColor: colors.onError,
                    ),
                    onPressed: () => onSos(false),
                    icon: const Icon(Icons.sos_rounded),
                    label: const Text('SOS'),
                  ),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: onEnd,
                    child: const Text('End journey'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A column that fills the screen normally and scrolls when it can't fit.
class _ScrollWhen extends StatelessWidget {
  const _ScrollWhen({required this.scroll, required this.children});

  final bool scroll;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (!scroll) return Column(children: children);
    return SingleChildScrollView(child: Column(children: children));
  }
}

/// Flexible space normally; a fixed gap inside a scrolling column.
class _Gap extends StatelessWidget {
  const _Gap({required this.scroll});

  final bool scroll;

  @override
  Widget build(BuildContext context) =>
      scroll ? const SizedBox(height: 20) : const Spacer();
}

class _CheckInPinDialog extends StatefulWidget {
  const _CheckInPinDialog();

  @override
  State<_CheckInPinDialog> createState() => _CheckInPinDialogState();
}

class _CheckInPinDialogState extends State<_CheckInPinDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final pin = _controller.text.trim();
    if (RegExp(r'^\d{4}$').hasMatch(pin)) {
      Navigator.of(context).pop(pin);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Enter check-in PIN'),
      content: TextField(
        key: const ValueKey('journey-check-in-pin'),
        controller: _controller,
        autofocus: true,
        obscureText: true,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        maxLength: 4,
        decoration: const InputDecoration(
          labelText: '4-digit PIN',
          counterText: '',
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Continue')),
      ],
    );
  }
}

class _SharingChip extends StatelessWidget {
  const _SharingChip({required this.status});

  final SharingStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (icon, label) = switch (status) {
      SharingStatus(error: 'location_denied') => (
        Icons.location_disabled_outlined,
        'Location is off, so contacts cannot see where you are',
      ),
      SharingStatus(error: 'gps_unavailable') => (
        Icons.gps_off_outlined,
        'Waiting for GPS',
      ),
      SharingStatus(active: false) => (
        Icons.location_off_outlined,
        'Live location off',
      ),
      SharingStatus(recipients: 0) => (
        Icons.person_off_outlined,
        'No contact has accepted yet, so nobody sees your location',
      ),
      SharingStatus(accuracyMeters: null) => (
        Icons.gps_not_fixed,
        'Finding your location…',
      ),
      _ => (
        Icons.my_location,
        'Live location shared with your contacts · within ${status.accuracyMeters!.round()} m',
      ),
    };
    return Container(
      key: const ValueKey('sharing-status'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: colors.onPrimaryContainer),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              style: TextStyle(color: colors.onPrimaryContainer, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
