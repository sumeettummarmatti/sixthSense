import 'package:flutter/material.dart';

/// "Lamplight Lavender": colours sampled from the SixthSense logo (Images/TAKE2.png).
/// Preview: https://claude.ai/artifact/5KNxV34PQeqNBWBQMXM6Xz
///
/// Rules:
/// - Red ([sos]) is only for SOS / active escalation. Never decorative.
/// - No green anywhere: green reads as "safe", and we never label a place safe.
/// - The PIN screen must look identical for the real and the duress PIN.
class AppColors {
  AppColors._();

  // Brand (light)
  static const ink = Color(0xFF2E2658);
  static const lavender = Color(0xFF7C55C6);
  static const deepViolet = Color(0xFF4C3892);
  static const mist = Color(0xFFF7F0FD);
  static const haze = Color(0xFFDCD1F6);
  static const glow = Color(0xFFEBDDFA);
  static const lamp = Color(0xFFFDF9FA);
  static const muted = Color(0xFF6E6790);

  // Status
  static const sos = Color(0xFFC8364B);
  static const arrived = Color(0xFF2F7D78);
  static const caution = Color(0xFF8A5A00);

  // Evidence labels (map). Deliberately no "safe" colour.
  static const evidenceStrong = Color(0xFFC8364B);
  static const evidenceSome = Color(0xFFC08A2E);
  static const evidenceInsufficient = Color(0xFF9A95B2);

  // Night
  static const night = Color(0xFF17132B);
  static const nightSurface = Color(0xFF211C3A);
  static const nightLine = Color(0xFF332C54);
  static const moonlight = Color(0xFFEEE8FA);
  static const nightMuted = Color(0xFFA9A2C6);
  static const nightLavender = Color(0xFFA98BEA);
  static const nightSos = Color(0xFFE0566A);
  static const nightArrived = Color(0xFF5DB3AC);
}

const _lightScheme = ColorScheme(
  brightness: Brightness.light,
  primary: AppColors.lavender,
  onPrimary: Colors.white,
  primaryContainer: AppColors.glow,
  onPrimaryContainer: AppColors.deepViolet,
  secondary: AppColors.deepViolet,
  onSecondary: Colors.white,
  tertiary: AppColors.arrived,
  onTertiary: Colors.white,
  error: AppColors.sos,
  onError: Colors.white,
  surface: AppColors.mist,
  onSurface: AppColors.ink,
  onSurfaceVariant: AppColors.muted,
  surfaceContainerLowest: AppColors.lamp,
  surfaceContainerLow: AppColors.lamp,
  surfaceContainer: AppColors.lamp,
  surfaceContainerHigh: AppColors.glow,
  outline: AppColors.haze,
  outlineVariant: AppColors.haze,
);

const _darkScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: AppColors.nightLavender,
  onPrimary: AppColors.night,
  primaryContainer: Color(0xFF2A2347),
  onPrimaryContainer: AppColors.nightLavender,
  secondary: AppColors.nightLavender,
  onSecondary: AppColors.night,
  tertiary: AppColors.nightArrived,
  onTertiary: AppColors.night,
  error: AppColors.nightSos,
  onError: AppColors.night,
  surface: AppColors.night,
  onSurface: AppColors.moonlight,
  onSurfaceVariant: AppColors.nightMuted,
  surfaceContainerLowest: AppColors.night,
  surfaceContainerLow: AppColors.nightSurface,
  surfaceContainer: AppColors.nightSurface,
  surfaceContainerHigh: Color(0xFF2A2347),
  outline: AppColors.nightLine,
  outlineVariant: AppColors.nightLine,
);

ThemeData buildTheme(Brightness brightness) {
  final scheme = brightness == Brightness.light ? _lightScheme : _darkScheme;
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    cardTheme: CardThemeData(
      color: scheme.surfaceContainer,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outline),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        side: BorderSide(color: scheme.outline, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
  );
}
