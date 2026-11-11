import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';

class JourneyFlow extends StatefulWidget {
  const JourneyFlow({
    super.key,
    this.now,
    this.onDuressRequested,
    this.onCovertSosRequested,
  });

  final DateTime Function()? now;
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

  void _startJourney(JourneyPlan plan) {
    _ticker?.cancel();
    setState(() {
      _plan = plan;
      _checkInDue = false;
      _nextCheckIn = _now().add(plan.checkInInterval);
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

  void _checkIn() {
    final plan = _plan;
    if (plan == null) return;
    setState(() {
      _checkInDue = false;
      _nextCheckIn = _now().add(plan.checkInInterval);
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
      widget.onDuressRequested?.call();
      _checkIn();
    } else if (pin == plan.realPin) {
      _wrongPinAttempts = 0;
      _checkIn();
    } else {
      _wrongPinAttempts++;
      if (_wrongPinAttempts >= 3) {
        _wrongPinAttempts = 0;
        widget.onDuressRequested?.call();
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That PIN did not match. Try again.')),
      );
    }
  }

  Future<void> _requestSos(bool covert) async {
    if (covert) {
      widget.onCovertSosRequested?.call();
      await HapticFeedback.heavyImpact();
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('SOS requested'),
        content: const Text(
          'This prototype cannot contact anyone yet. If you need emergency help, call 112 from your phone.',
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
    );
  }
}

@immutable
class JourneyPlan {
  const JourneyPlan({
    required this.destination,
    required this.checkInInterval,
    required this.realPin,
    required this.duressPin,
  });

  final String destination;
  final Duration checkInInterval;
  final String realPin;
  final String duressPin;
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
  var _selectedMinutes = 5;

  static const _intervals = [1, 5, 10, 15];

  @override
  void dispose() {
    _destinationController.dispose();
    _realPinController.dispose();
    _duressPinController.dispose();
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
    widget.onStart(
      JourneyPlan(
        destination: destination,
        checkInInterval: Duration(minutes: _selectedMinutes),
        realPin: realPin,
        duressPin: duressPin,
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
                          'Prototype only: PINs are held in memory, and SOS/duress do not alert anyone. Background notifications are not connected yet.',
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
  });

  final JourneyPlan plan;
  final Duration remaining;
  final bool isCheckInDue;
  final VoidCallback onCheckIn;
  final VoidCallback onEnd;
  final ValueChanged<bool> onSos;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final text = theme.textTheme;
    final intervalSeconds = plan.checkInInterval.inSeconds;
    final timerDiameter = MediaQuery.sizeOf(context).height < 700
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
                        Column(
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
                        'This prototype does not send an alert if you miss a check-in.',
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
