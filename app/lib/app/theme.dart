/// LLMMBC look and feel: Material 3, brand green, calm neutrals.
library;

import 'package:flutter/material.dart';

/// Brand color taken from `assets/icon.svg`.
const Color kBrandSeed = Color(0xFF059669);

const String kMonoFont = 'monospace';

ThemeData buildLlmmbcTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: kBrandSeed, brightness: brightness);
  final isLight = brightness == Brightness.light;
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);

  final border = scheme.outlineVariant.withValues(alpha: isLight ? 0.55 : 0.4);

  return base.copyWith(
    scaffoldBackgroundColor: isLight ? const Color(0xFFF6F8F6) : const Color(0xFF0E1211),
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      backgroundColor: isLight ? const Color(0xFFF6F8F6) : const Color(0xFF0E1211),
      surfaceTintColor: Colors.transparent,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: isLight ? Colors.white : scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: border)),
    ),
    dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: isLight ? const Color(0xFFF0F3F0) : const Color(0xFF131917),
      indicatorColor: scheme.primaryContainer,
      selectedLabelTextStyle: TextStyle(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w600),
      unselectedLabelTextStyle: TextStyle(color: scheme.onSurfaceVariant),
      labelType: NavigationRailLabelType.all,
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 68,
      backgroundColor: isLight ? Colors.white : const Color(0xFF131917),
      indicatorColor: scheme.primaryContainer,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isLight ? Colors.white : scheme.surfaceContainerLow,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: scheme.primary, width: 1.6)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: border)),
      labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      side: BorderSide(color: border),
    ),
    sliderTheme: base.sliderTheme.copyWith(
      trackHeight: 4,
      activeTrackColor: scheme.primary,
      thumbColor: scheme.primary,
    ),
    textTheme: base.textTheme.copyWith(
      headlineSmall: base.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.4),
      titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      labelLarge: base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    ),
  );
}

/// Monospace style used for identifiers, paths and hardware counters.
TextStyle monoStyle(BuildContext context, {double size = 12, Color? color}) => TextStyle(
      fontFamily: kMonoFont,
      fontFamilyFallback: const ['Roboto Mono', 'DejaVu Sans Mono', 'Courier New'],
      fontSize: size,
      color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
      height: 1.35,
    );
