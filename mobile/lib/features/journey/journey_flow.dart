import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/journey/journey_runtime.dart';
import '../../core/theme/app_theme.dart';
import '../walk/walk_flow.dart';
import '../map/map_route_screen.dart';

class JourneyFlow extends StatefulWidget {
  const JourneyFlow({
    super.key,
    this.now,
    this.runtime = const JourneyRuntime(),
    this.onDuressRequested,
    this.onCovertSosRequested,
  });

  final DateTime Function()? now;
  final JourneyRuntime runtime;
  final VoidCallback? onDuressRequested;
  final VoidCallback? onCovertSosRequested;

  @override
  State<JourneyFlow> createState() => _JourneyFlowState();
}

class _JourneyFlowState extends State<JourneyFlow> with WidgetsBindingObserver {
  JourneyPlan? _plan;
  DateTime? _nextCheckIn;
  Timer? _ticker;
  Duration _remaining = Duration.zero;
  bool _checkInDue = false;
  var _wrongPinAttempts = 0;
  late final DateTime Function() _now;

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
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _plan != null) {
      _updateCountdown();
    }
  }

  Future<void> _startJourney(JourneyPlan plan) async {
    final nextCheckIn = _now().add(plan.checkInInterval);
    try {
      await widget.runtime.startJourney(
        nextCheckIn: nextCheckIn,
        smsNumbers: plan.smsNumbers,
        smsFallbackEnabled: plan.smsFallbackEnabled,
      );
    } on PlatformException catch (error) {
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
      _nextCheckIn = nextCheckIn;
      _remaining = plan.checkInInterval;
    });
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _updateCountdown(),
    );
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
      return;
    }
    setState(() => _remaining = remaining);
  }

  Future<void> _checkIn() async {
    final plan = _plan;
    if (plan == null) return;
    final nextCheckIn = _now().add(plan.checkInInterval);
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
      _nextCheckIn = nextCheckIn;
      _remaining = plan.checkInInterval;
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
      await _checkIn();
    } else if (pin == plan.realPin) {
      _wrongPinAttempts = 0;
      await _checkIn();
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
    if (covert) {
      await widget.runtime.requestCovertSos();
      widget.onCovertSosRequested?.call();
      await HapticFeedback.heavyImpact();
      return;
    }
    final smsSubmitted = await widget.runtime.requestSos();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('SOS requested'),
        content: Text(
          smsSubmitted
              ? 'A safety SMS was submitted to Android for sending. If you need emergency help, call 112 from your phone.'
              : 'No SMS was sent. Offline SMS works only during an opted-in journey when internet is unavailable. If you need emergency help, call 112 from your phone.',
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
      setState(() {
        _plan = null;
        _nextCheckIn = null;
        _remaining = Duration.zero;
        _checkInDue = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    if (plan == null) {
      return JourneySetupScreen(onStart: _startJourney);
    }
    return ActiveJourneyScreen(
      plan: plan,
      remaining: _remaining,
      isCheckInDue: _checkInDue,
      onCheckIn: _enterCheckInPin,
      onEnd: _endJourney,
      onSos: _requestSos,
      onRequestBatteryExemption: _requestBatteryExemption,
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
  });

  final String destination;
  final Duration checkInInterval;
  final String realPin;
  final String duressPin;
  final List<String> smsNumbers;
  final bool smsFallbackEnabled;
}

class JourneySetupScreen extends StatefulWidget {
  const JourneySetupScreen({super.key, required this.onStart});

  final ValueChanged<JourneyPlan> onStart;

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
      appBar: AppBar(title: const Text('Plan a journey')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
              children: [
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
                TextField(
                  key: const ValueKey('journey-destination'),
                  controller: _destinationController,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.place_outlined),
                    hintText: 'Destination',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _start(),
                ),
                const SizedBox(height: 28),
                Text('Check in every', style: text.titleSmall),
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
  });

  final JourneyPlan plan;
  final Duration remaining;
  final bool isCheckInDue;
  final VoidCallback onCheckIn;
  final VoidCallback onEnd;
  final ValueChanged<bool> onSos;
  final VoidCallback onRequestBatteryExemption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final text = theme.textTheme;
    final intervalSeconds = plan.checkInInterval.inSeconds;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final timerDiameter = screenHeight < 700 ? 184.0 : 224.0;
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
            ).push(MaterialPageRoute<void>(builder: (_) => const WalkFlow())),
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
              child: Column(
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
                  const Spacer(),
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
                  const Spacer(),
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
                        'A missed check-in does not alert your contacts yet.',
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
