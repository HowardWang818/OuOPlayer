import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/lyrics/lyrics_service.dart';
import 'package:ouoplayer/ui/widgets/lyrics_view.dart';

LrclibResult lrc(String text, {bool synced = true, int secs = 213}) =>
    LrclibResult(title: 'アイドル', artist: 'YOASOBI', album: '', durationSec: secs, synced: synced ? text : null, plain: synced ? null : text);

void main() {
  const japanese = '[00:12.00]無敵の笑顔で荒らすメディア\n[00:15.00]知りたいその秘密ミステリアス';
  const romaji = '[00:12.00]Muteki no egao de arasu media\n[00:15.00]Shiritai sono himitsu misuteriasu';
  const mixed = '[00:12.00]無敵の笑顔で荒らすメディア\n[00:12.50]Muteki no egao de arasu media';

  test('script share tells the original from romaji', () {
    expect(scriptShare(japanese), greaterThan(0.9));
    expect(scriptShare(romaji), lessThan(0.05));
    expect(lrc(japanese).scriptLabel, '日文');
    expect(lrc(romaji).scriptLabel, '羅馬拼音／英文');
    expect(lrc(mixed).scriptLabel, '混合');
    expect(lrc('[00:01.00]晴天的雨').scriptLabel, '中文');
  });

  test('the original wins over romaji, even if only the romaji is synced', () {
    final picked = LyricsService.pickBest([lrc(romaji), lrc(mixed), lrc(japanese, synced: false)], durationMs: 213000, preferNative: true);
    expect(picked!.text, japanese);
    // Romaji is still better than nothing.
    expect(LyricsService.pickBest([lrc(romaji)], preferNative: true)!.text, romaji);
    // A Latin-titled song: the original still wins when both versions exist…
    expect(LyricsService.pickBest([lrc(romaji), lrc(japanese)])!.text, japanese);
    // …but an English song keeps synced-first as before.
    expect(LyricsService.pickBest([lrc('[00:01]hello world', synced: false), lrc('[00:01]hello there')])!.synced, isNotNull);
    expect(hasNativeScript(const Track(id: 'a', uri: 'a', title: 'アイドル')), isTrue);
    expect(hasNativeScript(const Track(id: 'a', uri: 'a', title: 'Lemon', artist: 'Kenshi Yonezu')), isFalse);
  });

  test('lyrics colours: light text on dark backgrounds and dark text on light ones', () {
    Widget child = const SizedBox();
    final onDark = LyricsInk.on(const Color(0xFF1B2A6B), child: child);
    final onLight = LyricsInk.on(const Color(0xFFF2F0E6), child: child);
    expect(onDark.strong, Colors.white);
    expect(ThemeData.estimateBrightnessForColor(onLight.strong), Brightness.dark);
  });
}
