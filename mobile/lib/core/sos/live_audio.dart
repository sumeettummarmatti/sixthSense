import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../location/live_location.dart';
import 'sudden_sos.dart';

/// Plays the live audio of people I support (SOS recording or Audio Escort)
/// for the sessions I chose to listen to. Each clip is written to the app's
/// cache, played once and deleted (the native player removes it), so nothing
/// heard stays on this phone.
class LiveAudioPlayer {
  LiveAudioPlayer._();

  static final instance = LiveAudioPlayer._();

  /// Journeys (sessions) I'm listening to right now.
  final listeningTo = ValueNotifier<Set<String>>({});
  StreamSubscription<ReceivedAudio>? _subscription;
  final _lastSequence = <String, int>{};

  void start(LiveLocationRelay relay) {
    _subscription ??= relay.audio.listen(_onClip);
  }

  bool isListening(String sessionId) => listeningTo.value.contains(sessionId);

  void listen(String sessionId) {
    listeningTo.value = {...listeningTo.value, sessionId};
  }

  Future<void> mute(String sessionId) async {
    listeningTo.value = {...listeningTo.value}..remove(sessionId);
    _lastSequence.remove(sessionId);
    await SuddenSos.instance.stopPlayback();
  }

  /// Stop listening to every session not in [stillOpen] (alert or escort over).
  Future<void> keepOnly(Set<String> stillOpen) async {
    final ended = listeningTo.value.difference(stillOpen);
    if (ended.isEmpty) return;
    for (final id in ended) {
      await mute(id);
    }
  }

  Future<void> _onClip(ReceivedAudio clip) async {
    if (!isListening(clip.sessionId)) return;
    final last = _lastSequence[clip.sessionId];
    // Clips missed while offline arrive first, in order; skip duplicates.
    if (last != null && clip.sequence <= last && clip.kind == 'escort') return;
    _lastSequence[clip.sessionId] = clip.sequence;
    try {
      final file = File(
        '${Directory.systemTemp.path}/live-${clip.sessionId}-${clip.kind}-${clip.sequence}.aac',
      );
      await file.writeAsBytes(clip.bytes, flush: true);
      await SuddenSos.instance.playClip(file.path);
    } catch (error) {
      debugPrint('LiveAudioPlayer could not play a clip: $error');
    }
  }
}
