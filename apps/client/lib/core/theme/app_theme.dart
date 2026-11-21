import 'package:flutter/material.dart';

/// Shared dark-studio color palette and Material 3 theme for HyperDownload.
abstract final class AppColors {
  static const indigo = Color(0xFF6366F1);
  static const primary = Color(0xFF818CF8);
  static const onPrimary = Color(0xFF0A0D18);
  static const primaryContainer = Color(0xFF283066);
  static const onPrimaryContainer = Color(0xFFE0E7FF);

  static const cyan = Color(0xFF22D3EE);
  static const onSecondary = Color(0xFF052029);
  static const secondaryContainer = Color(0xFF143647);
  static const onSecondaryContainer = Color(0xFFCFFAFE);

  static const emerald = Color(0xFF34D399);
  static const onTertiary = Color(0xFF062319);
  static const tertiaryContainer = Color(0xFF15362B);
  static const onTertiaryContainer = Color(0xFFD1FAE5);

  static const error = Color(0xFFFB7185);
  static const errorContainer = Color(0xFF3B1522);
  static const onErrorContainer = Color(0xFFFFE4E6);

  static const appBar = Color(0xFF0D111E);
  static const inputFill = Color(0xFF0D121F);
  static const surfaceLowest = Color(0xFF0A0D16);
  static const surface = Color(0xFF121726);
  static const surfaceLow = Color(0xFF171E31);
  static const surfaceHighest = Color(0xFF222B45);
  static const onSurface = Color(0xFFF1F5F9);
  static const onSurfaceVariant = Color(0xFF94A3B8);
  static const outline = Color(0xFF475569);
  static const outlineVariant = Color(0xFF26314D);
}

/// Application themes for HyperDownload.
abstract final class AppTheme {
  static final ColorScheme darkColorScheme =
      ColorScheme.fromSeed(
        seedColor: AppColors.indigo,
        brightness: Brightness.dark,
      ).copyWith(
        primary: AppColors.primary,
        onPrimary: AppColors.onPrimary,
        primaryContainer: AppColors.primaryContainer,
        onPrimaryContainer: AppColors.onPrimaryContainer,
        secondary: AppColors.cyan,
        onSecondary: AppColors.onSecondary,
        secondaryContainer: AppColors.secondaryContainer,
        onSecondaryContainer: AppColors.onSecondaryContainer,
        tertiary: AppColors.emerald,
        onTertiary: AppColors.onTertiary,
        tertiaryContainer: AppColors.tertiaryContainer,
        onTertiaryContainer: AppColors.onTertiaryContainer,
        error: AppColors.error,
        errorContainer: AppColors.errorContainer,
        onErrorContainer: AppColors.onErrorContainer,
        surface: AppColors.surface,
        onSurface: AppColors.onSurface,
        onSurfaceVariant: AppColors.onSurfaceVariant,
        surfaceContainerLowest: AppColors.surfaceLowest,
        surfaceContainerLow: AppColors.surfaceLow,
        surfaceContainerHighest: AppColors.surfaceHighest,
        outline: AppColors.outline,
        outlineVariant: AppColors.outlineVariant,
      );

  static final ThemeData dark = _buildDarkTheme();

  static ThemeData _buildDarkTheme() {
    final scheme = darkColorScheme;
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surfaceContainerLowest,
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.appBar,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surface,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.inputFill,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.secondary, width: 1.6),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return scheme.primaryContainer;
            }
            return scheme.surfaceContainerLow;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return scheme.onPrimaryContainer;
            }
            return scheme.onSurfaceVariant;
          }),
          side: WidgetStatePropertyAll(
            BorderSide(color: scheme.outlineVariant),
          ),
        ),
      ),
    );
  }
}
