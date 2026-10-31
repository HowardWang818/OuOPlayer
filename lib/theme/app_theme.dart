import 'dart:io';

import 'package:flutter/material.dart';

class AppColors {
  static const accent = Color(0xFF1DBEEF);
  static const darkBg = Color(0xFF121212);
  static const darkSurface = Color(0xFF181818);
  static const darkCard = Color(0xFF242424);
  static const lightBg = Color(0xFFFFFFFF);
  static const lightSurface = Color(0xFFF4F6F8);
  static const lightCard = Color(0xFFE9EDF0);

  // Windows: more contrast in the dark theme.
  static const desktopDarkBg = Color(0xFF0E0E0E);
  static const desktopDarkSurface = Color(0xFF151515);
  static const desktopDarkCard = Color(0xFF2E2E2E);

  /// Windows, light theme: the player bar.
  static const desktopLightBar = Color(0xFFF1F8FE);

  // Windows, light theme: [accent] made darker for a light background: the
  // main colour (bars, active icons, chosen items),
  // the play button, under the mouse, icons not in use, the bars' empty part.
  static const desktopLightMain = Color(0xFF0B93C4);
  static const desktopLightPlay = Color(0xFF0B7FAE);
  static const desktopLightHover = accent;
  static const desktopLightIcon = Color(0xFF64748B);
  static const desktopLightTrack = Color(0xFFE2E8F0);
}

/// Marks a theme that uses the light blues.
class _LightBlues extends ThemeExtension<_LightBlues> {
  const _LightBlues();

  @override
  _LightBlues copyWith() => this;

  @override
  _LightBlues lerp(_LightBlues? other, double t) => this;
}

class AppTheme {
  static bool get _desktop => Platform.isWindows;

  /// Windows, light theme (its own blues), and the phone's light player.
  static bool lightDesktop(BuildContext context) => Theme.of(context).extension<_LightBlues>() != null;

  /// The phone's light player has the same controls as Windows; everything
  /// else stays as it is.
  static ThemeData playerControls(ThemeData theme) => _desktop || theme.brightness != Brightness.light ? theme : blueControls(theme);

  /// [theme] with Windows' light blues on its buttons and bars.
  @visibleForTesting
  static ThemeData blueControls(ThemeData theme) => theme.copyWith(
        extensions: const [_LightBlues()],
        colorScheme: theme.colorScheme.copyWith(primary: AppColors.desktopLightMain, onPrimary: Colors.white, secondary: AppColors.desktopLightMain),
        iconButtonTheme: IconButtonThemeData(
          style: ButtonStyle(
            foregroundColor: WidgetStateProperty.resolveWith(
                (s) => s.contains(WidgetState.disabled) || s.contains(WidgetState.selected) ? null : AppColors.desktopLightIcon),
          ),
        ),
        sliderTheme: theme.sliderTheme.copyWith(
          activeTrackColor: AppColors.desktopLightMain,
          inactiveTrackColor: AppColors.desktopLightTrack,
          thumbColor: AppColors.desktopLightMain,
        ),
        chipTheme: theme.chipTheme.copyWith(selectedColor: AppColors.desktopLightMain),
      );

  /// White on a dark background, near-black on a light one.
  static Color inkOn(Color background) => ThemeData.estimateBrightnessForColor(background) == Brightness.dark ? Colors.white : const Color(0xFF111111);

  /// Like [inkOn], softer: text on a light background is dark grey.
  static Color textOn(Color background) => ThemeData.estimateBrightnessForColor(background) == Brightness.dark ? Colors.white : const Color(0xFF444444);

  /// The app's colour here.
  static Color accent(BuildContext context) => Theme.of(context).colorScheme.primary;

  /// The play button's colour.
  static Color control(BuildContext context) => lightDesktop(context) ? AppColors.desktopLightPlay : Theme.of(context).colorScheme.onSurface;

  /// The play button's symbol.
  static Color controlSymbol(BuildContext context) => lightDesktop(context) ? Colors.white : Theme.of(context).scaffoldBackgroundColor;

  /// Windows, light theme: a player bar button that is [on] (or always blue),
  /// lighter under the mouse. Null elsewhere.
  static ButtonStyle? barButton(BuildContext context, {bool on = true}) => !lightDesktop(context)
      ? null
      : ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.hovered)
              ? AppColors.desktopLightHover
              : on
                  ? AppColors.desktopLightMain
                  : AppColors.desktopLightIcon),
        );

  /// The player bar's background.
  static Color playerBar(BuildContext context) {
    final theme = Theme.of(context);
    return _desktop && theme.brightness == Brightness.light ? AppColors.desktopLightBar : theme.colorScheme.surfaceContainer;
  }

  static ThemeData dark() => _build(
        brightness: Brightness.dark,
        bg: _desktop ? AppColors.desktopDarkBg : AppColors.darkBg,
        surface: _desktop ? AppColors.desktopDarkSurface : AppColors.darkSurface,
        card: _desktop ? AppColors.desktopDarkCard : AppColors.darkCard,
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
    final lightDesktop = _desktop && brightness == Brightness.light;
    final main = lightDesktop ? AppColors.desktopLightMain : AppColors.accent;
    final onMain = lightDesktop ? Colors.white : Colors.black;
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.accent,
      brightness: brightness,
    ).copyWith(
      primary: main,
      onPrimary: onMain,
      secondary: main,
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
      extensions: lightDesktop ? const [_LightBlues()] : null,
      // Windows: buttons have no background under the mouse; their symbol
      // gets brighter and a little bigger.
      iconButtonTheme: !_desktop
          ? null
          : IconButtonThemeData(
              style: ButtonStyle(
                overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                // A fixed box: the symbol growing under the mouse moves nothing around it.
                fixedSize: const WidgetStatePropertyAll(Size.square(40)),
                padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                foregroundColor: WidgetStateProperty.resolveWith((s) {
                  if (s.contains(WidgetState.disabled) || s.contains(WidgetState.selected)) return null;
                  if (s.contains(WidgetState.hovered)) return lightDesktop ? AppColors.desktopLightHover : onBg;
                  return lightDesktop ? AppColors.desktopLightIcon : null;
                }),
                iconSize: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.hovered) ? 26 : null),
              ),
            ),
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
        activeTrackColor: main,
        inactiveTrackColor: lightDesktop ? AppColors.desktopLightTrack : muted.withValues(alpha: 0.3),
        thumbColor: lightDesktop ? main : onBg,
        overlayShape: SliderComponentShape.noOverlay,
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      ),
      listTileTheme: ListTileThemeData(iconColor: muted, textColor: onBg),
      chipTheme: ChipThemeData(
        backgroundColor: card,
        selectedColor: main,
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
          backgroundColor: main,
          foregroundColor: onMain,
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: main),
      dividerTheme: DividerThemeData(color: muted.withValues(alpha: 0.2)),
    );
  }
}
