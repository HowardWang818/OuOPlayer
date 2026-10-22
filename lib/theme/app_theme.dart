import 'package:flutter/material.dart';

class AppColors {
  static const accent = Color(0xFF1DBEEF);
  static const darkBg = Color(0xFF121212);
  static const darkSurface = Color(0xFF181818);
  static const darkCard = Color(0xFF242424);
  static const lightBg = Color(0xFFFFFFFF);
  static const lightSurface = Color(0xFFF4F6F8);
  static const lightCard = Color(0xFFE9EDF0);
}

class AppTheme {
  static ThemeData dark() => _build(
        brightness: Brightness.dark,
        bg: AppColors.darkBg,
        surface: AppColors.darkSurface,
        card: AppColors.darkCard,
        onBg: Colors.white,
        muted: const Color(0xFFB3B3B3),
      );

  static ThemeData light() => _build(
        brightness: Brightness.light,
        bg: AppColors.lightBg,
        surface: AppColors.lightSurface,
        card: AppColors.lightCard,
        onBg: const Color(0xFF111111),
        muted: const Color(0xFF5E6A73),
      );

  static ThemeData _build({
    required Brightness brightness,
    required Color bg,
    required Color surface,
    required Color card,
    required Color onBg,
    required Color muted,
  }) {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.accent,
      brightness: brightness,
    ).copyWith(
      primary: AppColors.accent,
      onPrimary: Colors.black,
      secondary: AppColors.accent,
      surface: bg,
      onSurface: onBg,
      onSurfaceVariant: muted,
      surfaceContainer: surface,
      surfaceContainerHigh: card,
      surfaceContainerHighest: card,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      fontFamilyFallback: const ['Microsoft JhengHei', 'Noto Sans TC', 'sans-serif'],
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: onBg,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(color: onBg, fontSize: 22, fontWeight: FontWeight.bold),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        indicatorColor: Colors.transparent,
        iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
              color: s.contains(WidgetState.selected) ? onBg : muted,
            )),
        labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
              fontSize: 11,
              color: s.contains(WidgetState.selected) ? onBg : muted,
            )),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: AppColors.accent,
        inactiveTrackColor: muted.withValues(alpha: 0.3),
        thumbColor: onBg,
        overlayShape: SliderComponentShape.noOverlay,
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      ),
      listTileTheme: ListTileThemeData(iconColor: muted, textColor: onBg),
      chipTheme: ChipThemeData(
        backgroundColor: card,
        selectedColor: AppColors.accent,
        labelStyle: TextStyle(color: onBg),
        side: BorderSide.none,
        shape: const StadiumBorder(),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: card,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.black,
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.accent),
      dividerTheme: DividerThemeData(color: muted.withValues(alpha: 0.2)),
    );
  }
}
