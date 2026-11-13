import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/sos/sudden_sos.dart';

/// Set up and practise Sudden SOS: the shortcuts, the microphone, the
/// offline voice pack, a practice mode that sends nothing, and the SOS
/// recordings kept on this phone.
class SuddenSosScreen extends StatefulWidget {
  const SuddenSosScreen({super.key, this.sos});

  final SuddenSos? sos;

  @override
  State<SuddenSosScreen> createState() => _SuddenSosScreenState();
}

class _SuddenSosScreenState extends State<SuddenSosScreen> {
  SuddenSos get _sos => widget.sos ?? SuddenSos.instance;

  var _mic = false;
  var _models = <String>[];
  var _recordings = <Recording>[];
  var _practising = false;
  final _heard = <String>[];
  StreamSubscription<GuardEvent>? _events;

  @override
  void initState() {
    super.initState();
    _events = _sos.events.listen(_onEvent);
    _load();
  }

  @override
  void dispose() {
    _events?.cancel();
    if (_practising) unawaited(_sos.stopPractice());
    super.dispose();
  }

  Future<void> _load() async {
    final mic = await _sos.micPermission();
    final models = await _sos.installedVoiceModels();
    final recordings = await _sos.recordings();
    if (!mounted) return;
    setState(() {
      _mic = mic;
      _models = models;
      _recordings = recordings;
    });
  }

  void _onEvent(GuardEvent event) {
    if (!mounted) return;
    switch (event.name) {
      case 'heard':
        final word = event.args['word'] as String? ?? '?';
        final seconds = event.args['countdownSeconds'];
        setState(
          () => _heard.insert(
            0,
            word == 'volume'
                ? 'Volume buttons: an SOS would count down $seconds s'
                : 'Heard “$word”: an SOS would count down $seconds s',
          ),
        );
      case 'transcript' when _practising:
        setState(() => _heard.insert(0, 'Heard: “${event.args['text']}”'));
      case 'modelDone':
        final ok = event.args['ok'] == true;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ok
                  ? 'Voice pack ready. It works offline.'
                  : 'Download failed. Try again on Wi-Fi.',
            ),
          ),
        );
        _load();
    }
  }

  Future<void> _togglePractice() async {
    if (_practising) {
      await _sos.stopPractice();
      setState(() => _practising = false);
      return;
    }
    if (!await _sos.requestMicPermission()) {
      await _load();
      return;
    }
    final started = await _sos.startPractice();
    if (!mounted) return;
    if (!started) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Practice is off during a journey: the journey is already listening.',
          ),
        ),
      );
      return;
    }
    setState(() {
      _practising = true;
      _heard.clear();
      _mic = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final colors = theme.colorScheme;
    final voiceReady = _models.length == 2;
    return Scaffold(
      appBar: AppBar(title: const Text('Sudden SOS')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Text('No time to unlock?', style: text.headlineSmall),
          const SizedBox(height: 8),
          Text(
            'During a journey, with the screen off and the phone in your pocket:',
            style: text.bodyLarge,
          ),
          const SizedBox(height: 12),
          const _Way(
            icon: Icons.volume_down_rounded,
            title: 'Press Volume Down 5 times quickly',
            body: 'Or hold it down. The phone buzzes 3 times, then sends the SOS after 5 seconds.',
          ),
          const _Way(
            icon: Icons.record_voice_over_rounded,
            title: 'Say “help”, “bachao”, “madad” or “bacha lo”',
            body: 'Heard on the phone only, offline. A short countdown starts (3–9 s); saying it again sends at once.',
          ),
          const _Way(
            icon: Icons.grid_view_rounded,
            title: 'Quick Settings tile or home-screen widget',
            body: 'Starts the same countdown.',
          ),
          const SizedBox(height: 6),
          Text(
            'Only your PIN in the app cancels the countdown. Your duress PIN looks like it cancels, but sends the SOS. '
            'After an SOS the phone records audio (including the 15 seconds before), encrypted, and plays it live to the people helping you.',
            style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
          ),
          const Divider(height: 36),
          Text('Microphone', style: text.titleMedium),
          const SizedBox(height: 6),
          Text(
            _mic
                ? 'Allowed. It is used only during a journey (with a notification) or while you practise.'
                : 'Needed for voice SOS and the SOS recording.',
            style: text.bodyMedium,
          ),
          if (!_mic)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('allow-mic'),
                onPressed: () async {
                  await _sos.requestMicPermission();
                  await _load();
                },
                child: const Text('Allow microphone'),
              ),
            ),
          const Divider(height: 36),
          Text('Voice pack', style: text.titleMedium),
          const SizedBox(height: 6),
          ValueListenableBuilder<int?>(
            valueListenable: _sos.modelProgress,
            builder: (context, progress, _) {
              if (progress != null) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Downloading… $progress%'),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(value: progress / 100),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    voiceReady
                        ? 'Installed: Hindi and Indian English. Works offline.'
                        : 'Hindi + Indian English speech models, about 80 MB, downloaded once (Wi-Fi recommended). '
                              'Free and open source. Nothing you say ever leaves the phone. Kannada is not available yet.',
                    style: text.bodyMedium,
                  ),
                  if (!voiceReady)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const ValueKey('download-voice'),
                        onPressed: _sos.downloadVoiceModels,
                        icon: const Icon(Icons.download_rounded),
                        label: const Text('Download voice pack'),
                      ),
                    ),
                ],
              );
            },
          ),
          const Divider(height: 36),
          Text('Practice', style: text.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Try the words and the volume buttons. Nothing is sent and nothing is recorded.',
            style: text.bodyMedium,
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            key: const ValueKey('practice'),
            onPressed: voiceReady || _practising ? _togglePractice : null,
            icon: Icon(_practising ? Icons.stop_rounded : Icons.mic_rounded),
            label: Text(_practising ? 'Stop practice' : 'Start practice'),
          ),
          if (!voiceReady && !_practising)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Download the voice pack first.',
                style: text.bodySmall,
              ),
            ),
          for (final line in _heard.take(8))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.check_circle_outline_rounded),
              title: Text(line),
            ),
          const Divider(height: 36),
          Text('SOS recordings on this phone', style: text.titleMedium),
          const SizedBox(height: 6),
          if (_recordings.isEmpty)
            Text('None.', style: text.bodyMedium)
          else
            for (final recording in _recordings)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.graphic_eq_rounded),
                title: Text(
                  '${MaterialLocalizations.of(context).formatShortDate(recording.lastModified)} · '
                  '${TimeOfDay.fromDateTime(recording.lastModified).format(context)}',
                ),
                subtitle: Text(
                  '~${(recording.seconds / 60).ceil()} min · encrypted on this phone',
                ),
                trailing: Wrap(
                  children: [
                    IconButton(
                      tooltip: 'Save or share (for a police complaint)',
                      onPressed: () => _sos.exportRecording(recording.session),
                      icon: const Icon(Icons.ios_share_rounded),
                    ),
                    IconButton(
                      tooltip: 'Delete',
                      onPressed: () async {
                        await _sos.deleteRecording(recording.session);
                        await _load();
                      },
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

class _Way extends StatelessWidget {
  const _Way({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.titleSmall),
                const SizedBox(height: 2),
                Text(body, style: text.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
