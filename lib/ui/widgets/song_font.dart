import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';

/// Windows: the typeface of song titles and artists in the player (設定 →
/// 播放 → 歌名字體): the system's bold is wide and heavy there.
enum SongFont {
  noto600('Noto 粗', 'NotoSansTC', 600),
  noto500('Noto 中', 'NotoSansTC', 500),
  yuGothic('Yu Gothic', 'Yu Gothic', 500);

  const SongFont(this.label, this.family, this.weight);
  final String label;
  final String family;
  final int weight;

  static SongFont parse(String? v) => values.where((f) => f.name == v).firstOrNull ?? noto500;

  TextStyle _with(TextStyle base, int wght) => !Platform.isWindows
      ? base
      : base.copyWith(
          fontFamily: family,
          fontWeight: FontWeight.values[(wght ~/ 100) - 1],
          fontVariations: [FontVariation('wght', wght.toDouble())],
        );

  TextStyle title(TextStyle base) => _with(base, weight);
  TextStyle artist(TextStyle base) => _with(base, 400);
}

class SongFontNotifier extends Notifier<SongFont> {
  @override
  SongFont build() {
    _load();
    return SongFont.noto500;
  }

  Future<void> _load() async => state = SongFont.parse((await ref.read(dbProvider).allSettings())['song_font']);

  void set(SongFont f) {
    state = f;
    ref.read(dbProvider).setSetting('song_font', f.name);
  }
}

final songFontProvider = NotifierProvider<SongFontNotifier, SongFont>(SongFontNotifier.new);

/// Windows: the colour the title bar takes while a page wants it (the full
/// player's gradient goes all the way up); null: the usual colour.
class TitleBarTint extends Notifier<Color?> {
  @override
  Color? build() => null;
  void set(Color? c) => state = c;
}

final titleBarTintProvider = NotifierProvider<TitleBarTint, Color?>(TitleBarTint.new);
