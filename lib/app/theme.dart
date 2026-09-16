import 'package:flutter/material.dart';

import '../core/ble/rssi.dart';

class AppTheme {
  AppTheme._();

  static const seed = Color(0xFF1B5E5A);

  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness b) {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: b);
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      fontFamilyFallback: const ['UmkreisEmoji'],
      appBarTheme: AppBarTheme(centerTitle: false, backgroundColor: scheme.surface),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        color: scheme.surfaceContainerLow,
      ),
      inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(), filled: true),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      chipTheme: ChipThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
    );
  }

  static Color proximityColor(Proximity p, ColorScheme scheme) => switch (p) {
        Proximity.veryNear => const Color(0xFF2E7D32),
        Proximity.near => const Color(0xFFF9A825),
        Proximity.inRange => scheme.outline,
      };
}
