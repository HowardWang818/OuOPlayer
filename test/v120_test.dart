import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/lyrics/lyrics_service.dart';
import 'package:ouoplayer/services/native_names.dart';
import 'package:ouoplayer/services/online/itunes.dart';

Track _t(String title, String artist, {int ms = 259000, String album = '未知專輯'}) =>
    Track(id: title, uri: '/m/$title.m4a', title: title, artist: artist, album: album, durationMs: ms, source: TrackSource.download);

ITunesSong _s(String title, String artist, int sec, {String album = ''}) =>
    ITunesSong(id: title.hashCode, title: title, artist: artist, album: album, viewUrl: '', durationMs: sec * 1000);

void main() {
  group('romaji lyrics', () {
    // Made-up lines, not real lyrics.
    final romaji = List.filled(4, 'kimi no koe ga kikoeru yoru ni hashiru shizuka na machi de boku wa matteru kyou mo ashita mo').join('\n');
    final english = List.filled(4, 'I walked along the empty street tonight and thought about the things we said before').join('\n');

    test('romaji is told apart from English and from the original', () {
      expect(looksRomaji('[00:01.00] $romaji'), isTrue);
      expect(looksRomaji(english), isFalse);
      expect(looksRomaji('君の声が聞こえる夜に走る 静かな街で僕は待ってる'), isFalse);
      // Too short to tell.
      expect(looksRomaji('kimi no koe'), isFalse);
    });
  });

  group('Japanese names', () {
    test('a romaji download gets its Japanese title, artist and album', () {
      final n = NativeNames.pick(_t('Yoru ni Kakeru', 'YOASOBI'), [
        _s('夜に駆ける', 'YOASOBI', 259, album: '夜に駆ける - Single'),
      ])!;
      expect((n.title, n.artist, n.album), ('夜に駆ける', 'YOASOBI', '夜に駆ける'));
      final m = NativeNames.pick(_t('Lemon', 'Kenshi Yonezu', ms: 256000), [_s('Lemon', '米津玄師', 256)])!;
      expect((m.title, m.artist), ('Lemon', '米津玄師'));
    });

    test('covers, other lengths and other artists are left alone', () {
      final t = _t('Uchiage Hanabi', 'DAOKO', ms: 289000);
      expect(
          NativeNames.pick(t, [
            _s('打上花火 (Piano Ver.)', 'Piano Echoes', 289),
            _s('打上花火 (オルゴール)', 'オルゴールサウンド J-POP', 289),
            _s('打上花火', 'DAOKO × 米津玄師', 300),
          ]),
          isNull);
      // Someone else's song of the same length, below iTunes' top hit.
      expect(NativeNames.pick(_t('Some Song', 'Ed Sheeran'), [_s('Some Song', 'Ed Sheeran', 180), _s('ある歌', '別の人', 259)]), isNull);
    });

    test('a Latin release of the same name makes it uncertain', () {
      final t = _t('Idol', 'YOASOBI', ms: 213000);
      expect(NativeNames.pick(t, [_s('アイドル', 'YOASOBI', 213), _s('Idol', 'YOASOBI', 213)]), isNull);
    });

    test('only songs named in Latin letters are looked up', () {
      expect(NativeNames.wants(_t('Yoru ni Kakeru', 'YOASOBI')), isTrue);
      expect(NativeNames.wants(_t('夜に駆ける', 'YOASOBI')), isFalse);
      expect(NativeNames.wants(const Track(id: 'u', uri: 'https://x/a.mp3', title: 'Idol', source: TrackSource.url)), isFalse);
    });
  });
}
