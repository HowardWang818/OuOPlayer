import 'dart:math';

import 'package:flutter/material.dart';

/// One mode (dark or light) of a colour theme: every colour the app paints
/// with. Built from a few colours by [Palette.derive], or given in full.
class Palette {
  const Palette({
    required this.bg,
    required this.surface,
    required this.card,
    required this.bar,
    required this.frame,
    required this.main,
    required this.onMain,
    required this.play,
    required this.onPlay,
    required this.hover,
    required this.icon,
    required this.track,
    required this.text,
    required this.muted,
  });

  /// Page background.
  final Color bg;

  /// Side bar, bottom navigation.
  final Color surface;

  /// Cards, chips, text fields.
  final Color card;

  /// The player bar.
  final Color bar;

  /// Windows: behind the panels and in the title bar (v1.17.2: in the theme's
  /// colour, a step darker than the panels, instead of black).
  final Color frame;

  /// The theme's colour: active icons, chosen items, sliders, buttons.
  final Color main;
  final Color onMain;

  /// The round play button and its symbol.
  final Color play;
  final Color onPlay;

  /// A player-bar button under the mouse.
  final Color hover;

  /// Icons not in use.
  final Color icon;

  /// A slider's empty part.
  final Color track;
  final Color text;
  final Color muted;

  bool get dark => ThemeData.estimateBrightnessForColor(bg) == Brightness.dark;

  /// 純黑深色: the page black (OLED), the rest darkened to match.
  Palette pureBlack() => !dark
      ? this
      : Palette(
          bg: Colors.black,
          surface: Color.lerp(Colors.black, surface, 0.55)!,
          card: Color.lerp(Colors.black, card, 0.8)!,
          bar: Color.lerp(Colors.black, bar, 0.55)!,
          frame: Colors.black,
          main: main,
          onMain: onMain,
          play: play,
          onPlay: onPlay == bg ? Colors.black : onPlay,
          hover: hover,
          icon: icon,
          track: track,
          text: text,
          muted: muted,
        );

  /// Light palettes with the theme's colour mixed into every background
  /// (v1.17.2: near-white ones hid it), the frame a step deeper; muted text
  /// and icons darkened as far as they need to stay readable.
  Palette tinted() {
    if (dark) return this;
    final b = Color.lerp(bg, main, 0.06)!;
    final s = Color.lerp(surface, main, 0.08)!;
    final m = withContrast(main, b, 3);
    return Palette(
      bg: b,
      surface: s,
      card: Color.lerp(card, main, 0.12)!,
      bar: Color.lerp(bar, main, 0.08)!,
      frame: Color.lerp(s, main, 0.14)!,
      main: m,
      onMain: m == main ? onMain : inkOn(m),
      play: play,
      onPlay: onPlay,
      hover: hover,
      icon: withContrast(icon, b, 3),
      track: Color.lerp(track, main, 0.15)!,
      text: withContrast(text, b, 4.5),
      muted: withContrast(muted, b, 4.5),
    );
  }

  /// The rest from [bg], [card], [main] and [text]. [main] is made lighter
  /// or darker when it would be hard to see on [bg]. Light ones are [tinted].
  factory Palette.derive({required Color bg, required Color card, required Color main, required Color text}) {
    final dark = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark;
    final m = withContrast(main, bg, 3);
    final p = Palette(
      bg: bg,
      surface: Color.lerp(bg, card, dark ? 0.35 : 0.45)!,
      card: card,
      bar: dark ? Color.lerp(bg, card, 0.35)! : Color.lerp(bg, m, 0.06)!,
      // Dark: the page colour a step darker, still in the theme's hue.
      frame: dark ? Color.lerp(bg, Colors.black, 0.45)! : bg,
      main: m,
      onMain: inkOn(m),
      // Dark: a light button with the page colour as its symbol; light: the theme's colour.
      play: dark ? text : withContrast(Color.lerp(m, Colors.black, 0.12)!, bg, 4.5),
      onPlay: dark ? bg : inkOn(withContrast(Color.lerp(m, Colors.black, 0.12)!, bg, 4.5)),
      hover: dark ? text : Color.lerp(m, Colors.white, 0.25)!,
      icon: Color.lerp(text, bg, dark ? 0.35 : 0.45)!,
      track: Color.lerp(bg, text, dark ? 0.22 : 0.14)!,
      text: text,
      muted: withContrast(Color.lerp(text, bg, 0.32)!, bg, 4.5),
    );
    return p.tinted();
  }
}

/// A colour theme: its dark and light palettes.
class ColorTheme {
  const ColorTheme(this.id, this.name, this.origin, this.dark, this.light);
  final String id;
  final String name;

  /// Where the colours come from (shown under the name).
  final String origin;
  final Palette dark;
  final Palette light;

  Palette of(Brightness b) => b == Brightness.dark ? dark : light;

  static const defaultId = 'clear_sky';

  /// A theme from one colour (主題 → 自訂): dark and light backgrounds,
  /// cards and text in its hue.
  factory ColorTheme.custom(Color seed) {
    final h = HSLColor.fromColor(seed).hue;
    Color hsl(double s, double l) => HSLColor.fromAHSL(1, h, s, l).toColor();
    return ColorTheme(
      'custom',
      '自訂',
      '你選的顏色',
      Palette.derive(bg: hsl(0.16, 0.06), card: hsl(0.14, 0.17), main: seed, text: hsl(0.25, 0.94)),
      Palette.derive(bg: hsl(0.5, 0.985), card: hsl(0.28, 0.92), main: seed, text: hsl(0.3, 0.12)),
    );
  }

  static ColorTheme byId(String? id, {Color? custom}) {
    if (id == 'custom' && custom != null) return ColorTheme.custom(custom);
    return presets.where((t) => t.id == id).firstOrNull ?? presets.first;
  }
}

Palette _p(int bg, int card, int main, int text) =>
    Palette.derive(bg: Color(bg), card: Color(card), main: Color(main), text: Color(text));

/// The built-in themes. 晴空 keeps OuOPlayer's own colours (the Windows ones
/// before v1.16.0); then well-known open palettes that come in a dark and a
/// light version; then four of OuOPlayer's own.
final presets = <ColorTheme>[
  ColorTheme(
    ColorTheme.defaultId,
    '晴空',
    'OuOPlayer 預設',
    const Palette(
      bg: Color(0xFF0E0E0E),
      surface: Color(0xFF151515),
      card: Color(0xFF2E2E2E),
      bar: Color(0xFF151515),
      frame: Color(0xFF070A0B),
      main: Color(0xFF1DBEEF),
      onMain: Colors.black,
      play: Colors.white,
      onPlay: Color(0xFF0E0E0E),
      hover: Colors.white,
      icon: Color(0xFFB3B3B3),
      track: Color(0x4DB3B3B3),
      text: Colors.white,
      muted: Color(0xFFB3B3B3),
    ),
    const Palette(
      bg: Color(0xFFFFFFFF),
      surface: Color(0xFFF4F6F8),
      card: Color(0xFFE9EDF0),
      bar: Color(0xFFF1F8FE),
      frame: Color(0xFFF4F6F8),
      main: Color(0xFF0B93C4),
      onMain: Colors.white,
      play: Color(0xFF0B7FAE),
      onPlay: Colors.white,
      hover: Color(0xFF1DBEEF),
      icon: Color(0xFF64748B),
      track: Color(0xFFE2E8F0),
      text: Color(0xFF111111),
      muted: Color(0xFF5E6A73),
    ).tinted(),
  ),
  ColorTheme('catppuccin', '貓布丁', 'Catppuccin Mocha／Latte', _p(0xFF1E1E2E, 0xFF313244, 0xFFCBA6F7, 0xFFCDD6F4),
      _p(0xFFEFF1F5, 0xFFCCD0DA, 0xFF8839EF, 0xFF4C4F69)),
  ColorTheme('nord', '北極', 'Nord', _p(0xFF2E3440, 0xFF3B4252, 0xFF88C0D0, 0xFFECEFF4), _p(0xFFECEFF4, 0xFFD8DEE9, 0xFF5E81AC, 0xFF2E3440)),
  ColorTheme('dracula', '德古拉', 'Dracula／Alucard', _p(0xFF282A36, 0xFF44475A, 0xFFBD93F9, 0xFFF8F8F2),
      _p(0xFFFFFBEB, 0xFFEFECDC, 0xFF644AC9, 0xFF1F1F1F)),
  ColorTheme('gruvbox', '復古', 'Gruvbox', _p(0xFF282828, 0xFF3C3836, 0xFFFE8019, 0xFFEBDBB2), _p(0xFFFBF1C7, 0xFFEBDBB2, 0xFFAF3A03, 0xFF3C3836)),
  ColorTheme('tokyo_night', '東京夜', 'Tokyo Night／Day', _p(0xFF1A1B26, 0xFF24283B, 0xFF7AA2F7, 0xFFC0CAF5),
      _p(0xFFE1E2E7, 0xFFC4C8DA, 0xFF2E7DE9, 0xFF3760BF)),
  ColorTheme('rose_pine', '玫瑰松', 'Rosé Pine／Dawn', _p(0xFF191724, 0xFF26233A, 0xFFEBBCBA, 0xFFE0DEF4),
      _p(0xFFFAF4ED, 0xFFF2E9E1, 0xFFD7827E, 0xFF575279)),
  ColorTheme('solarized', '日曬', 'Solarized', _p(0xFF002B36, 0xFF073642, 0xFF268BD2, 0xFF93A1A1), _p(0xFFFDF6E3, 0xFFEEE8D5, 0xFF268BD2, 0xFF586E75)),
  ColorTheme('everforest', '常青林', 'Everforest', _p(0xFF2D353B, 0xFF3D484D, 0xFFA7C080, 0xFFD3C6AA),
      _p(0xFFFDF6E3, 0xFFEFEBD4, 0xFF8DA101, 0xFF5C6A72)),
  ColorTheme('sakura', '櫻花', 'OuOPlayer', _p(0xFF1A1316, 0xFF2A1F24, 0xFFF4A7C0, 0xFFF5E6EC), _p(0xFFFFF7FA, 0xFFF7E6EC, 0xFFD6517F, 0xFF3A2830)),
  ColorTheme('forest', '森林', 'OuOPlayer', _p(0xFF0F1512, 0xFF1E2A24, 0xFF4ADE80, 0xFFE3F2E8), _p(0xFFF6FBF7, 0xFFE3EFE6, 0xFF16A34A, 0xFF14281C)),
  ColorTheme('sunset', '夕陽', 'OuOPlayer', _p(0xFF16110D, 0xFF2A211A, 0xFFFB923C, 0xFFF7E9DC), _p(0xFFFFF9F4, 0xFFF6E8DC, 0xFFEA580C, 0xFF3A2412)),
  ColorTheme('lavender', '薰衣草', 'OuOPlayer', _p(0xFF13111A, 0xFF241F33, 0xFFA78BFA, 0xFFECE7FB), _p(0xFFFAF8FF, 0xFFECE7F8, 0xFF7C3AED, 0xFF2A2142)),
];

/// WCAG contrast ratio of two colours (1–21).
double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (max(la, lb) + 0.05) / (min(la, lb) + 0.05);
}

/// [c], lighter (on a dark [bg]) or darker (on a light one) until it has
/// [ratio] contrast with [bg].
Color withContrast(Color c, Color bg, double ratio) {
  final dark = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark;
  var hsl = HSLColor.fromColor(c);
  for (var i = 0; i < 40 && contrast(hsl.toColor(), bg) < ratio; i++) {
    hsl = hsl.withLightness((hsl.lightness + (dark ? 0.02 : -0.02)).clamp(0.0, 1.0));
  }
  return hsl.toColor();
}

/// White or near-black, whichever reads better on [background].
Color inkOn(Color background) => contrast(Colors.white, background) >= contrast(const Color(0xFF111111), background) ? Colors.white : const Color(0xFF111111);
