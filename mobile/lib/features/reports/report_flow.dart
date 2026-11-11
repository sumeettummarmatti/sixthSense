import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'report_privacy.dart';

abstract interface class ReportLocationSource {
  Future<ExactReportLocation> getCurrentLocation();
}

class DeviceReportLocationSource implements ReportLocationSource {
  @override
  Future<ExactReportLocation> getCurrentLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const _ReportLocationException(
        'Turn on location services and try again.',
      );
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw const _ReportLocationException(
        'Location permission is needed to place the report.',
      );
    }
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
      ),
    );
    return ExactReportLocation(position.latitude, position.longitude);
  }
}

class _ReportLocationException implements Exception {
  const _ReportLocationException(this.message);
  final String message;
}

class ReportFlow extends StatefulWidget {
  const ReportFlow({super.key, this.locationSource, this.now, this.privacy});

  final ReportLocationSource? locationSource;
  final DateTime Function()? now;
  final ReportLocationPrivacy? privacy;

  @override
  State<ReportFlow> createState() => _ReportFlowState();
}

class _ReportFlowState extends State<ReportFlow> {
  late final ReportLocationSource _locationSource;
  late final ReportLocationPrivacy _privacy;
  late final DateTime Function() _now;
  ReportCondition? _condition;
  AnonymousReportPreview? _preview;
  bool _isPreparing = false;

  @override
  void initState() {
    super.initState();
    _locationSource = widget.locationSource ?? DeviceReportLocationSource();
    _privacy = widget.privacy ?? ReportLocationPrivacy();
    _now = widget.now ?? DateTime.now;
  }

  Future<void> _preparePreview() async {
    final condition = _condition;
    if (condition == null) return;
    setState(() {
      _isPreparing = true;
      _preview = null;
    });
    try {
      final exactLocation = await _locationSource.getCurrentLocation();
      final blurred = _privacy.blurLocation(exactLocation, _now());
      if (!mounted) return;
      setState(() {
        _preview = AnonymousReportPreview(
          condition: condition,
          location: blurred,
        );
      });
    } catch (error) {
      if (!mounted) return;
      final message = error is _ReportLocationException
          ? error.message
          : 'Could not prepare a location preview. Try again.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _isPreparing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Scaffold(
      appBar: AppBar(title: const Text('Report a place issue')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'What is the concern?',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 10),
            const Text(
              'Choose a place condition. This form has no free-text field, so it cannot collect a person’s name, phone number, or vehicle plate.',
            ),
            const SizedBox(height: 20),
            DropdownButtonFormField<ReportCondition>(
              key: const ValueKey('report-condition'),
              initialValue: _condition,
              decoration: const InputDecoration(
                labelText: 'Place condition',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final condition in ReportCondition.values)
                  DropdownMenuItem(
                    value: condition,
                    child: Text(condition.label),
                  ),
              ],
              onChanged: (condition) => setState(() {
                _condition = condition;
                _preview = null;
              }),
            ),
            const SizedBox(height: 18),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.location_searching_rounded),
              title: Text('Location stays on this phone until it is blurred'),
              subtitle: Text(
                'The report preview uses randomized ~100 m location noise and a two-hour time bucket.',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('prepare-report-preview'),
              onPressed: _condition == null || _isPreparing
                  ? null
                  : _preparePreview,
              icon: _isPreparing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.shield_outlined),
              label: const Text('Prepare anonymized preview'),
            ),
            if (preview != null) ...[
              const SizedBox(height: 20),
              Card(
                key: const ValueKey('report-preview'),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Anonymized preview',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 10),
                      Text(preview.condition.label),
                      const SizedBox(height: 6),
                      const Text('Approximate area · randomized on this phone'),
                      Text(preview.location.timeBucket),
                      const SizedBox(height: 10),
                      const Text(
                        'Nothing was uploaded. The P4 report endpoint is not connected.',
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
