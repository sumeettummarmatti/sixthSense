import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sixthsense_app/features/reports/report_flow.dart';
import 'package:sixthsense_app/features/reports/report_privacy.dart';

class _FakeLocationSource implements ReportLocationSource {
  @override
  Future<ExactReportLocation> getCurrentLocation() async =>
      const ExactReportLocation(12.9716, 77.5946);
}

void main() {
  test('adds planar location noise and rounds local time to two hours', () {
    const exact = ExactReportLocation(12.9716, 77.5946);
    final privacy = ReportLocationPrivacy(random: Random(42));
    final blurred = privacy.blurLocation(exact, DateTime(2026, 11, 10, 20, 30));
    final distance = _distanceMeters(
      exact.latitude,
      exact.longitude,
      blurred.latitude,
      blurred.longitude,
    );

    expect(distance, greaterThan(0));
    expect(distance, lessThan(1000));
    expect(blurred.timeBucket, 'Tue 8–10 pm');
    expect(blurred.latitude, inInclusiveRange(-90, 90));
    expect(blurred.longitude, inInclusiveRange(-180, 180));
  });

  test('report serialization contains only the noisy location and bucket', () {
    final blurred = ReportLocationPrivacy(random: Random(7)).blurLocation(
      const ExactReportLocation(12.9716, 77.5946),
      DateTime(2026, 11, 10, 20, 30),
    );
    final payload = AnonymousReportPreview(
      condition: ReportCondition.poorLighting,
      location: blurred,
    ).toJson();

    expect(payload['condition'], 'poorLighting');
    expect(payload['time_bucket'], 'Tue 8–10 pm');
    expect(payload, isNot(contains('user_id')));
    expect(payload.values, isNot(contains(12.9716)));
    expect(payload.values, isNot(contains(77.5946)));
  });

  testWidgets('report preview uses coarse values and sends nothing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ReportFlow(
          locationSource: _FakeLocationSource(),
          now: () => DateTime(2026, 11, 10, 20, 30),
          privacy: ReportLocationPrivacy(random: Random(42)),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('report-condition')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Poor street lighting').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('prepare-report-preview')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('report-preview')), findsOneWidget);
    expect(find.text('Tue 8–10 pm'), findsOneWidget);
    expect(
      find.text(
        'Nothing was uploaded. The P4 report endpoint is not connected.',
      ),
      findsOneWidget,
    );
    expect(find.text('12.9716'), findsNothing);
    expect(find.text('77.5946'), findsNothing);
  });
}

double _distanceMeters(double lat1, double lon1, double lat2, double lon2) {
  final radians = pi / 180;
  final deltaLat = (lat2 - lat1) * radians;
  final deltaLon = (lon2 - lon1) * radians;
  final x = deltaLon * cos((lat1 + lat2) * radians / 2);
  return 6371008.8 * sqrt(deltaLat * deltaLat + x * x);
}
