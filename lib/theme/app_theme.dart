import 'dart:io';

import 'package:flutter/material.dart';

import 'looks.dart';
import 'themes.dart';

/// The palette a theme was built from, for the colours Material has no slot
/// for (the play button, the player bar, icons not in use).
class PaletteExtension extends ThemeExtension<PaletteExtension> {
  const PaletteExtension(this.palette);
  final Palette palette;

  @override
  PaletteExtension copyWith({Palette? palette}) => PaletteExtension(palette ?? this.palette);

  @override
  PaletteExtension lerp(PaletteExtension? other, double t) => t < 0.5 || other == null ? this : other;
}

class AppTheme {
  static bool get _desktop => Platform.isWindows;

  /// The palette here (晴空's for a theme not built by [build], e.g. tests).
  static Palette palette(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<PaletteExtension>()?.palette ?? presets.first.of(theme.brightness);
  }

  /// Light themes colour their controls: a coloured play button with a white
  /// symbol, coloured bars, grey icons not in use (v1.16.0: on the phone too).
  static bool colouredControls(BuildContext context) => !palette(context).dark;

  /// White on a dark background, near-black on a light one.
  static Color inkOn(Color background) => ThemeData.estimateBrightnessForColor(background) == Brightness.dark ? Colors.white : const Color(0xFF111111);

  /// Like [inkOn], softer: text on a light background is dark grey.
  static Color textOn(Color background) => ThemeData.estimateBrightnessForColor(background) == Brightness.dark ? Colors.white : const Color(0xFF444444);

  /// The theme's colour here.
  static Color accent(BuildContext context) => Theme.of(context).colorScheme.primary;

  /// Liked songs' tile: from the theme's colour, a little round the colour wheel.
  static LinearGradient likedGradient(BuildContext context, {Alignment begin = Alignment.centerLeft, Alignment end = Alignment.centerRight}) {
    final main = accent(context);
    final hsl = HSLColor.fromColor(main);
    final from = hsl.withHue((hsl.hue + 50) % 360).withLightness((hsl.lightness * 0.85).clamp(0.0, 1.0));
    return LinearGradient(colors: [from.toColor(), main], begin: begin, end: end);
  }

  /// The play button's colour.
  static Color control(BuildContext context) => palette(context).play;

  /// The play button's symbol.
  static Color controlSymbol(BuildContext context) => palette(context).onPlay;

  /// Light themes: a player bar button that is [on] (or always coloured),
  /// lighter under the mouse. Null in dark themes.
  static ButtonStyle? barButton(BuildContext context, {bool on = true}) {
    if (!colouredControls(context)) return null;
    final p = palette(context);
    return ButtonStyle(
      foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.hovered)
          ? p.hover
          : on
              ? p.main
              : p.icon),
    );
  }

  /// The player bar's background.
  static Color playerBar(BuildContext context) => palette(context).bar;

  /// The app's theme for [palette] (one mode of a [ColorTheme]) with [looks].
  static ThemeData build(Palette palette, {Looks looks = const Looks()}) {
    final p = looks.pureBlack ? palette.pureBlack() : palette;
    double r(double v) => looks.radius(v);
    final brightness = p.dark ? Brightness.dark : Brightness.light;
    final coloured = !p.dark;
    final scheme = ColorScheme.fromSeed(seedColor: p.main, brightness: brightness).copyWith(
      primary: p.main,
      onPrimary: p.onMain,
      secondary: p.main,
      onSecondary: p.onMain,
      surface: p.bg,
      onSurface: p.text,
      onSurfaceVariant: p.muted,
      surfaceContainer: p.surface,
      surfaceContainerHigh: p.card,
      surfaceContainerHighest: p.card,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      extensions: [PaletteExtension(p), LooksExtension(looks)],
      cardTheme: CardThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r(12)))),
      dialogTheme: DialogThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r(28)))),
      bottomSheetTheme: BottomSheetThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(r(28))))),
      popupMenuTheme: PopupMenuThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r(8)))),
      segmentedButtonTheme: SegmentedButtonThemeData(
          style: ButtonStyle(shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(r(20)))))),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(shape: looks.corners == Corners.standard ? const StadiumBorder() : RoundedRectangleBorder(borderRadius: BorderRadius.circular(r(20))))),
      // Windows: buttons have no background under the mouse; their symbol
      // gets brighter and a little bigger. Light themes: grey when not in use.
      iconButtonTheme: !_desktop && !coloured
          ? null
          : IconButtonThemeData(
              style: ButtonStyle(
                overlayColor: _desktop ? const WidgetStatePropertyAll(Colors.transparent) : null,
                // A fixed box: the symbol growing under the mouse moves nothing around it.
                fixedSize: _desktop ? const WidgetStatePropertyAll(Size.square(40)) : null,
                padding: _desktop ? const WidgetStatePropertyAll(EdgeInsets.zero) : null,
                foregroundColor: WidgetStateProperty.resolveWith((s) {
                  if (s.contains(WidgetState.disabled) || s.contains(WidgetState.selected)) return null;
                  if (_desktop && s.contains(WidgetState.hovered)) return coloured ? p.hover : p.text;
                  return coloured ? p.icon : null;
                }),
                iconSize: _desktop ? WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.hovered) ? 26 : null) : null,
              ),
            ),
      scaffoldBackgroundColor: p.bg,
      canvasColor: p.bg,
      fontFamilyFallback: const ['Microsoft JhengHei', 'Noto Sans TC', 'sans-serif'],
      appBarTheme: AppBarTheme(
        backgroundColor: p.bg,
        foregroundColor: p.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(color: p.text, fontSize: 22, fontWeight: FontWeight.bold),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.surface,
        indicatorColor: Colors.transparent,
        iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
              color: s.contains(WidgetState.selected) ? (coloured ? p.main : p.text) : p.muted,
            )),
        labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
              fontSize: 11,
              color: s.contains(WidgetState.selected) ? (coloured ? p.main : p.text) : p.muted,
            )),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: p.main,
        inactiveTrackColor: p.track,
        thumbColor: coloured ? p.main : p.text,
        overlayShape: SliderComponentShape.noOverlay,
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      ),
      listTileTheme: ListTileThemeData(iconColor: p.muted, textColor: p.text),
      chipTheme: ChipThemeData(
        backgroundColor: p.card,
        selectedColor: p.main,
        labelStyle: TextStyle(color: p.text),
        side: BorderSide.none,
        shape: looks.corners == Corners.square ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(r(16))) : const StadiumBorder(),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.card,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(r(8)), borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.main,
          foregroundColor: p.onMain,
          shape: looks.corners == Corners.square ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(r(20))) : const StadiumBorder(),
          textStyle: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: p.main),
      dividerTheme: DividerThemeData(color: p.muted.withValues(alpha: 0.2)),
    );
  }
}
