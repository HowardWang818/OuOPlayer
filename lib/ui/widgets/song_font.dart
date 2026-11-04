import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../providers/providers.dart';

/// Windows: the Noto font ships next to the app (dataonts), not among the
/// assets both platforms share, so the phone's APK doesn't carry it.
Future<void> loadSongFont() async {
  if (!Platform.isWindows) return;
  try {
    final f = File(p.join(p.dirname(Platform.resolvedExecutable), 'data', 'fonts', 'NotoSansTC-VF.ttf'));
    if (!f.existsSync()) return;
    await (FontLoader('NotoSansTC')..addFont(f.readAsBytes().then(ByteData.sublistView))).load();
  } catch (_) {}
}

/// The typeface of song titles and artists in the player (設定 → 外觀 →
/// 歌名字體). Windows: the bundled Noto (the system's bold is wide and heavy
/// there) or Yu Gothic. Phone (v1.16.0): the system font, bold or medium.
enum SongFont {
  noto600('Noto 粗', 'NotoSansTC', 600),
  noto500('Noto 中', 'NotoSansTC', 500),
  yuGothic('Yu Gothic', 'Yu Gothic', 500);

  const SongFont(this.label_, this.family, this.weight);
  final String label_;
  final String family;
  final int weight;

  String get label => Platform.isWindows ? label_ : (weight >= 600 ? '粗' : '中');

  /// The choices on this platform.
  static List<SongFont> get available => Platform.isWindows ? values : const [noto600, noto500];

  static SongFont parse(String? v) => available.where((f) => f.name == v).firstOrNull ?? noto500;

  TextStyle _with(TextStyle base, int wght) => !Platform.isWindows
      ? base.copyWith(fontWeight: FontWeight.values[(wght ~/ 100) - 1])
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
