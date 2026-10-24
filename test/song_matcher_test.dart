import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/services/song_matcher.dart';

MatchLevel level(String t1, String a1, String t2, String a2, {int? d1, int? d2}) =>
    SongMatcher.compare(SongKey(t1, a1, durationMs: d1), SongKey(t2, a2, durationMs: d2)).level;

void main() {
  group('same song (sure)', () {
    final cases = <(String, String, String, String)>[
      ('韋禮安 WeiBird《如果可以 Red Scarf》MV - 電影「月老」主題曲導演親剪音樂視角版', '韋禮安 WeiBird', '如果可以', 'WeiBird'),
      ('YOASOBI「アイドル」Official Music Video', 'Ayase / YOASOBI', 'アイドル', 'YOASOBI'),
      ('【MV】怪物 / YOASOBI', 'YOASOBI', '怪物', 'YOASOBI'),
      ('群青', 'YOASOBI - Topic', '群青', 'YOASOBI'),
      ('Shape of You (Official Audio)', 'Ed Sheeran', 'Shape of You', 'Ed Sheeran'),
      ('Idol feat. Someone', 'YOASOBI', 'Idol', 'YOASOBI'),
      ('夜に駆ける', 'ＹＯＡＳＯＢＩ', '夜に駆ける', 'YOASOBI'),
      ('YOASOBI - 群青 / THE FIRST TAKE', 'THE FIRST TAKE', '群青', 'YOASOBI'),
      ('米津玄師 MV「Lemon」', '米津玄師', 'Lemon', 'Kenshi Yonezu, 米津玄師'),
      ('Propose', 'natori', 'propose', 'natori'),
      ('King Gnu - 白日', 'King Gnu', '白日', 'King Gnu'),
      ('Song - Remastered 2011', 'The Band', 'Song', 'The Band'),
    ];
    for (final (t1, a1, t2, a2) in cases) {
      test('$t1 = $t2', () => expect(level(t1, a1, t2, a2), MatchLevel.sure));
    }
  });

  group('not the same song', () {
    final cases = <(String, String, String, String)>[
      ('propose', 'natori', 'propose', '9Lana'),
      ('Love', 'X', 'Love Story', 'X'),
      ('如果', 'A', '如果可以', 'A'),
      ('愛', 'A', '愛してる', 'A'),
      ('群青', 'YOASOBI', '怪物', 'YOASOBI'),
      ('Lemon', '米津玄師', 'Lemon Tree', 'Fools Garden'),
    ];
    for (final (t1, a1, t2, a2) in cases) {
      test('$t1 ≠ $t2', () => expect(level(t1, a1, t2, a2), MatchLevel.no));
    }
  });

  group('maybe (the user decides)', () {
    test('artist unknown on one side', () => expect(level('群青', '未知演出者', '群青', 'YOASOBI'), MatchLevel.maybe));
    test('a typo in a long title', () => expect(level('夜に駆ける', 'YOASOBI', '夜に駆けろ', 'YOASOBI'), MatchLevel.maybe));
    test('a very different length (live take)', () {
      expect(level('群青', 'YOASOBI', '群青', 'YOASOBI', d1: 248000, d2: 300000), MatchLevel.maybe);
      expect(level('群青', 'YOASOBI', '群青', 'YOASOBI', d1: 248000, d2: 249000), MatchLevel.sure);
    });
  });

  group('helpers', () {
    test('folding', () {
      expect(foldText('ＹＯＡＳＯＢＩ：群青！'), 'yoasobi群青');
      expect(artistNames('韋禮安 WeiBird'), containsAll(['韋禮安', 'weibird']));
      expect(artistNames('YOASOBI - Topic'), ['yoasobi']);
      expect(artistNames('A feat. B'), containsAll(['a', 'b']));
      expect(artistNames('未知演出者'), isEmpty);
    });

    test('search text for lyrics and YouTube', () {
      expect(SongMatcher.searchTitle('韋禮安 WeiBird《如果可以 Red Scarf》MV - 電影「月老」主題曲', '韋禮安 WeiBird'), '如果可以 Red Scarf');
      expect(SongMatcher.searchTitle('【MV】怪物 / YOASOBI', 'YOASOBI'), '怪物');
      expect(SongMatcher.searchTitle('Shape of You (Official Audio)', 'Ed Sheeran'), 'Shape of You');
      expect(SongMatcher.searchArtist('YOASOBI - Topic'), 'YOASOBI');
      expect(SongMatcher.searchArtist('Ayase, YOASOBI'), 'Ayase');
    });

    test('index finds the best song', () {
      final songs = [('白日', 'King Gnu'), ('群青', 'YOASOBI'), ('韋禮安 WeiBird《如果可以 Red Scarf》MV', '韋禮安 WeiBird')];
      final index = SongIndex(songs, (s) => SongKey(s.$1, s.$2));
      final (found, r) = index.find(SongKey('如果可以', 'WeiBird'));
      expect((found?.$1, r.level), ('韋禮安 WeiBird《如果可以 Red Scarf》MV', MatchLevel.sure));
      expect(index.find(SongKey('propose', '9Lana')).$1, isNull);
    });
  });
}
