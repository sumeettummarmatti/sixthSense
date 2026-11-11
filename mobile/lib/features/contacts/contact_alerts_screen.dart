import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api/device_identity.dart';

/// The trusted contact's side of an alert. Shows only open alerts this person
/// is part of (rule 4); everything disappears once the alert is closed.
class ContactAlertsScreen extends StatefulWidget {
  const ContactAlertsScreen({
    super.key,
    this.api = const DemoApi(),
    this.pollInterval = const Duration(seconds: 5),
  });

  final DemoApi api;
  final Duration pollInterval;

  @override
  State<ContactAlertsScreen> createState() => _ContactAlertsScreenState();
}

class _ContactAlertsScreenState extends State<ContactAlertsScreen> {
  List<ContactAlert>? _alerts;
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

  Future<void> _refresh() async {
    try {
      final alerts = await widget.api.activeAlerts();
      if (mounted) {
        setState(() {
          _alerts = alerts;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not reach the server.');
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
      appBar: AppBar(title: const Text('People you support')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            children: [
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
                    onAck: () => _act(
                      alert,
                      widget.api.acknowledgeAlert,
                      'Others know you are on it.',
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
  });

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
            if (alert.acknowledged)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Someone is on it.',
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              )
            else
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: busy ? null : onAck,
                  child: const Text("I'm on it"),
                ),
              ),
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
