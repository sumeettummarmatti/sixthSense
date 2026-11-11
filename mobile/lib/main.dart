import 'package:flutter/material.dart';

import 'core/theme/app_theme.dart';
import 'features/onboarding/onboarding_flow.dart';

void main() => runApp(const SixthSenseApp());

class SixthSenseApp extends StatelessWidget {
  const SixthSenseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SixthSense',
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: const OnboardingFlow(),
    );
  }
}
