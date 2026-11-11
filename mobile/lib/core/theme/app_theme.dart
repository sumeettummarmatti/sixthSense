import 'package:flutter/material.dart';

/// Colours taken from the SixthSense logo.
class AppColors {
  static const ink = Color(0xFF1F1A33);
  static const accent = Color(0xFF6B46C1);
  static const background = Color(0xFFF7F4FC);
}

ThemeData buildTheme(Brightness brightness) => ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.accent,
        brightness: brightness,
      ),
    );
