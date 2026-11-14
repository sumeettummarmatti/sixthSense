import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A countdown started by the volume buttons or a distress word.
@immutable
class SosCountdown {
  const SosCountdown({
    required this.deadline,
    required this.source,
    this.heard,
  });

  final DateTime deadline;

  /// `button` or `voice`.
  final String source;

  /// The word that started it ("help", "बचाओ"), or `volume`.
  final String? heard;

  int secondsLeft(DateTime now) =>
      (deadline.difference(now).inMilliseconds / 1000).ceil().clamp(0, 99);
}

/// One recorded clip handed over by the phone (already decrypted from its
/// on-phone store), ready to be encrypted for the people listening.
@immutable
class NativeClip {
  const NativeClip({
    required this.session,
    required this.kind,
    required this.sequence,
    required this.bytes,
  });

  final String session;
  final String kind;
  final int sequence;
  final Uint8List bytes;
}

@immutable
class Recording {
  const Recording({
    required this.session,
    required this.seconds,
    required this.lastModified,
  });

  final String session;
  final int seconds;
  final DateTime lastModified;
}

/// Something the phone reported (`fired`, `heard`, `listening`, ...).
@immutable
class GuardEvent {
  const GuardEvent(this.name, this.args);

  final String name;
  final Map<String, Object?> args;
}

/// Sudden SOS on the phone (P1-W2): volume buttons and voice, the silent
/// countdown, the SOS recording, Audio Escort recording, playback of live
/// audio, and the offline voice models. The work runs in native code so it
/// keeps going with the screen off; this class is the app's handle on it.
/// Off Android, or in widget tests, every call is a harmless no-op.
class SuddenSos {
  SuddenSos._();

  static final instance = SuddenSos._();

  static const _channel = MethodChannel('in.sixthsense/sudden_sos');

  final countdown = ValueNotifier<SosCountdown?>(null);
  final modelProgress = ValueNotifier<int?>(null);
  final listening = ValueNotifier<bool>(false);
  final _events = StreamController<GuardEvent>.broadcast();

  Stream<GuardEvent> get events => _events.stream;

  bool _attached = false;

  void attach() {
    if (_attached) return;
    _attached = true;
    _channel.setMethodCallHandler((call) async {
      final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
      handleEvent(call.method, args);
      return null;
    });
  }

  /// Visible for tests: what happens when the phone reports [name].
  void handleEvent(String name, Map<String, Object?> args) {
    switch (name) {
      case 'countdown' || 'showCountdown':
        final deadline = (args['deadlineMillis'] as num?)?.toInt() ?? 0;
        final state = args['state'] as String?;
        if (deadline > 0 && (state == null || state == 'countdown')) {
          countdown.value = SosCountdown(
            deadline: DateTime.fromMillisecondsSinceEpoch(deadline),
            source: args['source'] as String? ?? 'button',
            heard: args['heard'] as String?,
          );
        }
      case 'cancelled' || 'fired':
        countdown.value = null;
      case 'listening':
        listening.value = args['listening'] == true;
      case 'modelProgress':
        modelProgress.value = (args['percent'] as num?)?.toInt();
      case 'modelDone':
        modelProgress.value = null;
    }
    _events.add(GuardEvent(name, args));
  }

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    if (!_supported) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null; // widget tests
    } on PlatformException catch (error) {
      debugPrint('SuddenSos.$method failed: ${error.message}');
      return null;
    }
  }

  /// Picks up a countdown that started while the app was in the background.
  Future<void> refresh() async {
    final state = await _invoke<Map>('guardState');
    if (state == null) return;
    final map = state.cast<String, Object?>();
    if (map['state'] == 'countdown') {
      handleEvent('showCountdown', map);
    } else if (countdown.value != null) {
      countdown.value = null;
    }
    listening.value = map['listening'] == true;
  }

  /// After the real PIN.
  Future<bool> cancelCountdown() async {
    countdown.value = null;
    return await _invoke<bool>('cancelCountdown') ?? false;
  }

  /// Sends the SOS now. [covert] (duress PIN): looks cancelled, no buzz,
  /// silent alarm. Returns false when no journey guard is running.
  Future<bool> fireNow({bool covert = false}) async {
    countdown.value = null;
    return await _invoke<bool>('fireNow', {'covert': covert}) ?? false;
  }

  Future<void> alertOver() => _invoke<void>('alertOver');

  Future<bool> startEscortRecording(String session, DateTime until) async =>
      await _invoke<bool>('startEscortRecording', {
        'session': session,
        'untilMillis': until.millisecondsSinceEpoch,
      }) ??
      false;

  Future<void> stopEscortRecording() => _invoke<void>('stopEscortRecording');

  Future<List<NativeClip>> takeClips(String kind) async {
    final raw = await _invoke<List>('takeClips', {'kind': kind});
    return [
      for (final item in raw ?? const [])
        if (item is Map)
          NativeClip(
            session: item['session'] as String,
            kind: item['kind'] as String,
            sequence: (item['sequence'] as num).toInt(),
            bytes: item['bytes'] as Uint8List,
          ),
    ];
  }

  Future<List<Recording>> recordings() async {
    final raw = await _invoke<List>('recordings');
    return [
      for (final item in raw ?? const [])
        if (item is Map)
          Recording(
            session: item['session'] as String,
            seconds: (item['seconds'] as num).toInt(),
            lastModified: DateTime.fromMillisecondsSinceEpoch(
              (item['lastModifiedMillis'] as num).toInt(),
            ),
          ),
    ];
  }

  Future<bool> exportRecording(String session) async =>
      await _invoke<bool>('exportRecording', {'session': session}) ?? false;

  Future<void> deleteRecording(String session) =>
      _invoke<void>('deleteRecording', {'session': session});

  Future<void> playClip(String path) =>
      _invoke<void>('playClip', {'path': path});

  Future<void> stopPlayback() => _invoke<void>('stopPlayback');

  Future<List<String>> installedVoiceModels() async {
    final raw = await _invoke<Map>('voiceModels');
    return [
      for (final item in (raw?['installed'] as List?) ?? const []) '$item',
    ];
  }

  Future<void> downloadVoiceModels() async {
    modelProgress.value = 0;
    await _invoke<void>('downloadVoiceModels');
  }

  Future<bool> micPermission() async =>
      await _invoke<bool>('micPermission') ?? false;

  Future<bool> requestMicPermission() async =>
      await _invoke<bool>('requestMicPermission') ?? false;

  /// False during a journey: the journey's guard is already listening.
  Future<bool> startPractice() async =>
      await _invoke<bool>('startPractice') ?? false;

  Future<void> stopPractice() => _invoke<void>('stopPractice');
}
