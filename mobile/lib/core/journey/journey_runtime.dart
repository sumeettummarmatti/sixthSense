import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class JourneyRuntime {
  const JourneyRuntime();

  static const _channel = MethodChannel('in.sixthsense/journey_runtime');

  /// [journeyId] and [apiBaseUrl] let the phone send a sudden SOS from
  /// native code, even with the app closed. [listenForWords] turns on Voice
  /// SOS for this journey.
  Future<void> startJourney({
    required DateTime nextCheckIn,
    List<String> smsNumbers = const [],
    bool smsFallbackEnabled = false,
    String? journeyId,
    String? apiBaseUrl,
    bool? listenForWords,
  }) => _invokeTimer(
    'startJourney',
    nextCheckIn: nextCheckIn,
    smsNumbers: smsNumbers,
    smsFallbackEnabled: smsFallbackEnabled,
    extra: {
      'journeyId': ?journeyId,
      'apiBaseUrl': ?apiBaseUrl,
      'listenForWords': ?listenForWords,
    },
  );

  Future<void> checkIn({
    required DateTime nextCheckIn,
    List<String> smsNumbers = const [],
    bool smsFallbackEnabled = false,
  }) => _invokeTimer(
    'checkIn',
    nextCheckIn: nextCheckIn,
    smsNumbers: smsNumbers,
    smsFallbackEnabled: smsFallbackEnabled,
  );

  Future<void> _invokeTimer(
    String method, {
    required DateTime nextCheckIn,
    required List<String> smsNumbers,
    required bool smsFallbackEnabled,
    Map<String, Object> extra = const {},
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>(method, {
      'deadlineMillis': nextCheckIn.millisecondsSinceEpoch,
      'smsNumbers': smsNumbers,
      'smsFallbackEnabled': smsFallbackEnabled,
      ...extra,
    });
  }

  Future<bool> requestSos() async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    return await _channel.invokeMethod<bool>('requestSos') ?? false;
  }

  Future<void> requestDuress() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<bool>('requestDuress');
  }

  Future<void> requestCovertSos() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<bool>('requestCovertSos');
  }

  Future<void> endJourney() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('endJourney');
  }

  Future<void> requestExactAlarmAccess() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('requestExactAlarmAccess');
  }

  Future<void> requestBatteryExemption() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('requestBatteryExemption');
  }

  Future<JourneyReliabilityStatus> getReliabilityStatus() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const JourneyReliabilityStatus(
        exactAlarmsAllowed: true,
        batteryExemptionGranted: true,
        notificationsAllowed: true,
      );
    }
    final status = await _channel.invokeMapMethod<String, bool>(
      'journeyReliabilityStatus',
    );
    return JourneyReliabilityStatus(
      exactAlarmsAllowed: status?['exactAlarmsAllowed'] ?? false,
      batteryExemptionGranted: status?['batteryExemptionGranted'] ?? false,
      notificationsAllowed: status?['notificationsAllowed'] ?? false,
    );
  }
}

@immutable
class JourneyReliabilityStatus {
  const JourneyReliabilityStatus({
    required this.exactAlarmsAllowed,
    required this.batteryExemptionGranted,
    required this.notificationsAllowed,
  });

  final bool exactAlarmsAllowed;
  final bool batteryExemptionGranted;
  final bool notificationsAllowed;
}
