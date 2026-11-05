import 'package:flutter/material.dart';

/// 播放頁 background: the cover's colour fading down (as before v1.17.0),
/// the cover itself blurred and dimmed, or the theme's plain background.
enum PlayerBackground { gradient, blur, solid }

/// 播放頁 cover: square, or a record that turns while playing.
enum CoverStyle { square, vinyl }

enum LyricsAlign { left, center }

/// Song lists: as before, or lower rows with smaller covers.
enum ListDensity { standard, compact }

/// Corners of covers, cards, bars, buttons, fields and dialogs.
enum Corners { round, standard, square }

/// The 外觀 choices besides the colour theme (v1.17.0).
@immutable
class Looks {
  const Looks({
    this.background = PlayerBackground.gradient,
    this.cover = CoverStyle.square,
    this.lyricsAlign = LyricsAlign.left,
    this.density = ListDensity.standard,
    this.corners = Corners.standard,
    this.pureBlack = false,
  });

  final PlayerBackground background;
  final CoverStyle cover;
  final LyricsAlign lyricsAlign;
  final ListDensity density;
  final Corners corners;

  /// Dark themes on #000000 (OLED).
  final bool pureBlack;

  bool get compact => density == ListDensity.compact;

  /// [r] as these corners have it.
  double radius(double r) => switch (corners) {
        // 4 → 12, 8 → 20, 12 → 28: clearly rounder; square stays square.
        Corners.round => r == 0 ? 0 : r * 2 + 4,
        Corners.standard => r,
        Corners.square => r * 0.25,
      };

  /// The settings they are kept in (synced with the colour theme).
  static const keys = ['look_bg', 'look_cover', 'look_lyrics_align', 'look_density', 'look_corners', 'look_black'];

  static T _pick<T extends Enum>(List<T> values, String? name, T fallback) => values.where((v) => v.name == name).firstOrNull ?? fallback;

  factory Looks.fromSettings(Map<String, String> s) => Looks(
        background: _pick(PlayerBackground.values, s['look_bg'], PlayerBackground.gradient),
        cover: _pick(CoverStyle.values, s['look_cover'], CoverStyle.square),
        lyricsAlign: _pick(LyricsAlign.values, s['look_lyrics_align'], LyricsAlign.left),
        density: _pick(ListDensity.values, s['look_density'], ListDensity.standard),
        corners: _pick(Corners.values, s['look_corners'], Corners.standard),
        pureBlack: s['look_black'] == 'true',
      );

  Map<String, String> toSettings() => {
        'look_bg': background.name,
        'look_cover': cover.name,
        'look_lyrics_align': lyricsAlign.name,
        'look_density': density.name,
        'look_corners': corners.name,
        'look_black': '$pureBlack',
      };

  Looks copyWith({PlayerBackground? background, CoverStyle? cover, LyricsAlign? lyricsAlign, ListDensity? density, Corners? corners, bool? pureBlack}) =>
      Looks(
        background: background ?? this.background,
        cover: cover ?? this.cover,
        lyricsAlign: lyricsAlign ?? this.lyricsAlign,
        density: density ?? this.density,
        corners: corners ?? this.corners,
        pureBlack: pureBlack ?? this.pureBlack,
      );

  /// The ones in effect here (the defaults outside the app's theme, e.g. tests).
  static Looks of(BuildContext context) => Theme.of(context).extension<LooksExtension>()?.looks ?? const Looks();

  @override
  bool operator ==(Object other) => other is Looks && _same(toSettings(), other.toSettings());

  @override
  int get hashCode => Object.hashAll(toSettings().values);

  static bool _same(Map<String, String> a, Map<String, String> b) => a.entries.every((e) => b[e.key] == e.value);
}

class LooksExtension extends ThemeExtension<LooksExtension> {
  const LooksExtension(this.looks);
  final Looks looks;

  @override
  LooksExtension copyWith({Looks? looks}) => LooksExtension(looks ?? this.looks);

  @override
  LooksExtension lerp(LooksExtension? other, double t) => t < 0.5 || other == null ? this : other;
}
