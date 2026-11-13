import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api/device_identity.dart';
import '../../core/contacts/contact_book.dart';
import '../../core/location/live_location.dart';
import '../../core/sos/live_audio.dart';
import '../../core/sos/sudden_sos.dart';

/// Four-digit PIN entry. Returns the PIN, or null if dismissed.
Future<String?> askPin(BuildContext context, {required String title}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _PinDialog(title: title),
    );

class _PinDialog extends StatefulWidget {
  const _PinDialog({required this.title});

  final String title;

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final pin = _controller.text.trim();
    if (RegExp(r'^\d{4}$').hasMatch(pin)) Navigator.of(context).pop(pin);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: const ValueKey('sos-pin'),
      controller: _controller,
      autofocus: true,
      keyboardType: TextInputType.number,
      obscureText: true,
      maxLength: 4,
      onSubmitted: (_) => _submit(),
      decoration: const InputDecoration(
        labelText: 'PIN',
        border: OutlineInputBorder(),
        counterText: '',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Back'),
      ),
      FilledButton(onPressed: _submit, child: const Text('OK')),
    ],
  );
}

/// Covers the journey screen while a sudden SOS counts down. Only the PIN
/// cancels it; the duress PIN makes it look cancelled and sends it at once.
class SosCountdownOverlay extends StatefulWidget {
  const SosCountdownOverlay({
    super.key,
    required this.countdown,
    required this.onEnterPin,
  });

  final SosCountdown countdown;
  final VoidCallback onEnterPin;

  @override
  State<SosCountdownOverlay> createState() => _SosCountdownOverlayState();
}

class _SosCountdownOverlayState extends State<SosCountdownOverlay> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final left = widget.countdown.secondsLeft(DateTime.now());
    final heard = widget.countdown.heard;
    final why = widget.countdown.source == 'voice'
        ? 'Started because the phone heard “${heard ?? 'help'}”.'
        : heard == 'volume'
        ? 'Started by the volume buttons.'
        : 'Started by the SOS shortcut.';
    return Positioned.fill(
      child: Material(
        key: const ValueKey('sos-countdown'),
        color: colors.inverseSurface.withValues(alpha: 0.96),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.sos_rounded, size: 56, color: colors.error),
                const SizedBox(height: 16),
                Text(
                  left > 0 ? 'Sending SOS in $left' : 'Sending SOS…',
                  style: text.headlineMedium?.copyWith(
                    color: colors.onInverseSurface,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                Text(
                  '$why Your contacts and verified responders nearby will be alerted and the phone will start recording.',
                  style: text.bodyLarge?.copyWith(
                    color: colors.onInverseSurface,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                FilledButton.icon(
                  key: const ValueKey('sos-cancel'),
                  onPressed: widget.onEnterPin,
                  icon: const Icon(Icons.pin_rounded),
                  label: const Text('Cancel with PIN'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// On the journey screen: start an Audio Escort, answer a contact's request,
/// or see the running one and stop it with the PIN.
class EscortPanel extends StatelessWidget {
  const EscortPanel({
    super.key,
    required this.escort,
    required this.requests,
    required this.names,
    required this.onStart,
    required this.onDecline,
    required this.onStop,
  });

  final Escort? escort;
  final List<EscortRequestView> requests;
  final Map<String, LocalContact> names;
  final void Function(String? requestId) onStart;
  final ValueChanged<String> onDecline;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final escort = this.escort;
    final request = requests.isEmpty ? null : requests.first;
    return Container(
      key: const ValueKey('escort-panel'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outline),
      ),
      child: escort != null
          ? Row(
              children: [
                Icon(Icons.hearing_rounded, color: colors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Audio escort on · ${_who(escort.listenerLinkIds)} listening · '
                    'until ${TimeOfDay.fromDateTime(escort.endsAt).format(context)}',
                    style: text.bodyMedium,
                  ),
                ),
                TextButton(
                  key: const ValueKey('escort-stop'),
                  onPressed: onStop,
                  child: const Text('Stop'),
                ),
              ],
            )
          : request != null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${names[request.contactLinkId]?.name ?? 'One of your contacts'} asks to keep you company by listening.',
                  style: text.bodyMedium,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    FilledButton.tonal(
                      key: const ValueKey('escort-accept'),
                      onPressed: () => onStart(request.id),
                      child: const Text('Start audio escort'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => onDecline(request.id),
                      child: const Text('No thanks'),
                    ),
                  ],
                ),
              ],
            )
          : Row(
              children: [
                Icon(Icons.hearing_outlined, color: colors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Let your people listen while you walk.',
                    style: text.bodyMedium,
                  ),
                ),
                TextButton(
                  key: const ValueKey('escort-start'),
                  onPressed: () => onStart(null),
                  child: const Text('Audio escort'),
                ),
              ],
            ),
    );
  }

  String _who(List<String> linkIds) {
    if (linkIds.length == 1) return names[linkIds.first]?.name ?? '1 contact';
    return '${linkIds.length} contacts';
  }
}

/// Choose who listens and for how long.
Future<(List<String>, int)?> chooseEscort(
  BuildContext context,
  DemoApi api,
  Map<String, LocalContact> names, {
  String? preselectedLinkId,
}) async {
  List<Map<String, dynamic>> contacts;
  try {
    contacts = (await api.listContacts())
        .where((c) => c['status'] == 'accepted')
        .toList();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not reach the server.')),
      );
    }
    return null;
  }
  if (!context.mounted) return null;
  if (contacts.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Add a trusted contact first (My people tab).'),
      ),
    );
    return null;
  }
  return showModalBottomSheet<(List<String>, int)>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _EscortSheet(
      contacts: contacts,
      names: names,
      preselected: preselectedLinkId,
    ),
  );
}

class _EscortSheet extends StatefulWidget {
  const _EscortSheet({
    required this.contacts,
    required this.names,
    this.preselected,
  });

  final List<Map<String, dynamic>> contacts;
  final Map<String, LocalContact> names;
  final String? preselected;

  @override
  State<_EscortSheet> createState() => _EscortSheetState();
}

class _EscortSheetState extends State<_EscortSheet> {
  late final Set<String> _chosen = {
    widget.preselected ?? widget.contacts.first['id'] as String,
  };
  var _minutes = 30;

  static const _lengths = [15, 30, 60, 120, 180];

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Audio escort', style: text.titleLarge),
            const SizedBox(height: 6),
            Text(
              'The people you pick hear what is around you, live, and see where you are until it ends. '
              'Your phone shows a notification the whole time. Stopping takes your PIN. Nothing is kept afterwards.',
              style: text.bodyMedium,
            ),
            const SizedBox(height: 14),
            Text('Who listens', style: text.titleSmall),
            for (final contact in widget.contacts)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _chosen.contains(contact['id']),
                title: Text(widget.names[contact['id']]?.name ?? 'Contact'),
                onChanged: (on) => setState(() {
                  final id = contact['id'] as String;
                  on == true ? _chosen.add(id) : _chosen.remove(id);
                }),
              ),
            const SizedBox(height: 8),
            Text('For how long', style: text.titleSmall),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                for (final minutes in _lengths)
                  ChoiceChip(
                    label: Text(
                      minutes < 60 ? '$minutes min' : '${minutes ~/ 60} h',
                    ),
                    selected: _minutes == minutes,
                    onSelected: (_) => setState(() => _minutes = minutes),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const ValueKey('escort-confirm'),
                onPressed: _chosen.isEmpty
                    ? null
                    : () =>
                          Navigator.of(context)
                              .pop((_chosen.toList(), _minutes)),
                icon: const Icon(Icons.hearing_rounded),
                label: const Text('Start'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Listen live" for someone I support, with a dot while audio is arriving.
class LiveAudioButton extends StatelessWidget {
  const LiveAudioButton({
    super.key,
    required this.sessionId,
    required this.relay,
  });

  final String sessionId;
  final LiveLocationRelay relay;

  @override
  Widget build(BuildContext context) {
    final player = LiveAudioPlayer.instance;
    final colors = Theme.of(context).colorScheme;
    return ValueListenableBuilder<Set<String>>(
      valueListenable: player.listeningTo,
      builder: (context, listening, _) =>
          ValueListenableBuilder<Map<String, DateTime>>(
            valueListenable: relay.liveAudio,
            builder: (context, clips, _) {
              final last = clips[sessionId];
              final live =
                  last != null &&
                  DateTime.now().difference(last) < const Duration(seconds: 15);
              final on = listening.contains(sessionId);
              return OutlinedButton.icon(
                key: ValueKey('listen-$sessionId'),
                onPressed: () =>
                    on ? player.mute(sessionId) : player.listen(sessionId),
                icon: Icon(
                  on ? Icons.volume_up_rounded : Icons.hearing_rounded,
                  color: live ? colors.error : null,
                ),
                label: Text(
                  on
                      ? (live
                            ? 'Listening live · tap to mute'
                            : 'Listening · waiting for audio')
                      : (live ? 'Live audio · tap to listen' : 'Listen live'),
                ),
              );
            },
          ),
    );
  }
}
