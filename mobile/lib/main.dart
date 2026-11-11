import 'package:flutter/material.dart';

import 'core/theme/app_theme.dart';

void main() => runApp(const SixthSenseApp());

class SixthSenseApp extends StatelessWidget {
  const SixthSenseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SixthSense',
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: const HomeScreen(),
    );
  }
}

/// Placeholder home. Real screens arrive in P1-W1 (sign-up, contacts) onwards.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('SixthSense', style: text.displaySmall),
              const SizedBox(height: 8),
              Text('See the risk. Stop it early.', style: text.titleMedium),
              const SizedBox(height: 32),
              FilledButton(onPressed: () {}, child: const Text('Start journey')),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: () {}, child: const Text('Walk with me')),
            ],
          ),
        ),
      ),
    );
  }
}
