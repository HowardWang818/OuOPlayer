// Compares every song matcher OuOPlayer has had on one labelled set of
// real-world cases and prints the numbers (run: flutter test test/matcher_comparison_test.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/services/download_match.dart' as old;
import 'package:ouoplayer/services/song_matcher.dart';
import 'package:ouoplayer/services/spotify_import.dart' show bareTitle;

/// (song on the phone: title, artist) vs (song wanted: title, artist), same song?
const cases = <(String, String, String, String, bool)>[
  // Plain, clean tags
  ('群青', 'YOASOBI', '群青', 'YOASOBI', true),
  ('Propose', 'natori', 'propose', 'natori', true),
  ('白日', 'King Gnu', '白日', 'King Gnu', true),
  ('Shape of You', 'Ed Sheeran', 'Shape of You', 'Ed Sheeran', true),
  ('夜に駆ける', 'ＹＯＡＳＯＢＩ', '夜に駆ける', 'YOASOBI', true),
  ('群青', 'YOASOBI - Topic', '群青', 'YOASOBI', true),
  // Notes in the title
  ('Shape of You (Official Audio)', 'Ed Sheeran', 'Shape of You', 'Ed Sheeran', true),
  ('Song - Remastered 2011', 'The Band', 'Song', 'The Band', true),
  ('Idol feat. Someone', 'YOASOBI', 'Idol', 'YOASOBI', true),
  ('Love Me Like You Do (Official Video)', 'Ellie Goulding', 'Love Me Like You Do', 'Ellie Goulding', true),
  // YouTube upload titles
  ('韋禮安 WeiBird《如果可以 Red Scarf》MV - 電影「月老」主題曲導演親剪音樂視角版', '韋禮安 WeiBird', '如果可以', 'WeiBird', true),
  ('YOASOBI「アイドル」Official Music Video', 'Ayase / YOASOBI', 'アイドル', 'YOASOBI', true),
  ('【MV】怪物 / YOASOBI', 'YOASOBI', '怪物', 'YOASOBI', true),
  ('米津玄師 MV「Lemon」', '米津玄師', 'Lemon', 'Kenshi Yonezu, 米津玄師', true),
  ('King Gnu - 白日', 'King Gnu', '白日', 'King Gnu', true),
  ('YOASOBI - 群青 / THE FIRST TAKE', 'THE FIRST TAKE', '群青', 'YOASOBI', true),
  ('李榮浩 Li Ronghao / 李白【歌詞】', 'HISMUSICS', '李白', 'Ronghao Li', true),
  ('周杰倫 Jay Chou【告白氣球 Love Confession】Official MV', '周杰倫 Jay Chou', '告白氣球', 'Jay Chou', true),
  ('Ado「唱」MV', 'Ado', '唱', 'Ado', true),
  // Names written differently
  ('李白', 'Li Ronghao', '李白', 'Ronghao Li', true),
  ('Bohemian Rhapsodyy', 'Queen', 'Bohemian Rhapsody', 'Queen', true),
  // Must NOT match
  ('propose', 'natori', 'propose', '9Lana', false),
  ('Love', 'X', 'Love Story', 'X', false),
  ('如果', 'A', '如果可以', 'A', false),
  ('愛', 'A', '愛してる', 'A', false),
  ('群青', 'YOASOBI', '怪物', 'YOASOBI', false),
  ('Lemon', '米津玄師', 'Lemon Tree', 'Fools Garden', false),
  ('李白', 'Ronghao Li', '李白', 'Li Bai Band', false),
  ('Someone Like You', 'Adele', 'Someone You Loved', 'Lewis Capaldi', false),
  ('Hello', 'Adele', 'Hello', 'Lionel Richie', false),
  ('Stay', 'Rihanna', 'Stay', 'The Kid LAROI', false),
  ('群青 (Live)', 'YOASOBI', 'ハルジオン', 'YOASOBI', false),
];

/// v0.6.0–v0.7.x: the download check, title (file name) only.
bool gen1(String t1, String a1, String t2, String a2) {
  final x = old.normalizeName(t1), y = old.normalizeName(t2);
  return x.isNotEmpty && (x == y || (x.length >= 30 && y.startsWith(x)));
}

/// v0.8.0–v0.12.x: same title, plus the artist (one name containing the other).
bool gen2(String t1, String a1, String t2, String a2) => gen1(t1, a1, t2, a2) && old.sameArtist(a1, a2);

/// v0.13.0: Spotify import — title or 「bare」 title, any of the artists.
bool gen3(String t1, String a1, String t2, String a2) {
  final titles1 = {old.normalizeName(t1), old.normalizeName(bareTitle(t1))};
  final titles2 = {old.normalizeName(t2), old.normalizeName(bareTitle(t2))};
  if (titles1.intersection(titles2).where((t) => t.isNotEmpty).isEmpty) return false;
  final artists2 = a2.split(RegExp(r'\s*[,;]\s*'));
  return artists2.any((a) => old.sameArtist(a, a1));
}

MatchLevel gen45(String t1, String a1, String t2, String a2) => SongMatcher.compare(SongKey(t1, a1), SongKey(t2, a2)).level;

class Score {
  int right = 0, wrongMatch = 0, missed = 0, asks = 0;
  String row(String name) {
    final positives = cases.where((c) => c.$5).length;
    final precision = right + wrongMatch == 0 ? 100.0 : right * 100 / (right + wrongMatch);
    return '$name | 自動對上 $right/$positives (${(right * 100 / positives).toStringAsFixed(0)}%) | 配錯 $wrongMatch | 漏掉 $missed | 問使用者 $asks | 準確率 ${precision.toStringAsFixed(0)}%';
  }
}

void main() {
  test('compare every matcher generation', () {
    final scores = <String, Score>{};
    void count(String gen, bool same, {required bool auto, bool ask = false}) {
      final s = scores.putIfAbsent(gen, Score.new);
      if (ask) {
        s.asks++;
      } else if (auto && same) {
        s.right++;
      } else if (auto && !same) {
        s.wrongMatch++;
      } else if (!auto && same) {
        s.missed++;
      }
    }

    final misses = <String, List<String>>{};
    for (final (t1, a1, t2, a2, same) in cases) {
      for (final (gen, f) in [('1. v0.6–0.7 只比歌名', gen1), ('2. v0.8–0.12 歌名+歌手', gen2), ('3. v0.13 Spotify 匯入', gen3)]) {
        final m = f(t1, a1, t2, a2);
        count(gen, same, auto: m);
        if (m != same) misses.putIfAbsent(gen, () => []).add('${same ? '漏' : '錯'}：$t1 / $t2');
      }
      for (final (gen, fuzz) in [('4. v0.14.0 統一比對器', false), ('5. v0.14.1 + rapidfuzz', true)]) {
        SongMatcher.wordOrderChecks = fuzz;
        final l = gen45(t1, a1, t2, a2);
        count(gen, same, auto: l == MatchLevel.sure, ask: l == MatchLevel.maybe);
        if ((l == MatchLevel.sure) != same && l != MatchLevel.maybe) misses.putIfAbsent(gen, () => []).add('${same ? '漏' : '錯'}：$t1 / $t2');
      }
    }
    SongMatcher.wordOrderChecks = true;
    // ignore: avoid_print
    print('\n${cases.length} 組（${cases.where((c) => c.$5).length} 組是同一首、${cases.where((c) => !c.$5).length} 組不是）');
    for (final e in scores.entries) {
      // ignore: avoid_print
      print(e.value.row(e.key));
      for (final m in misses[e.key] ?? const []) {
        // ignore: avoid_print
        print('     $m');
      }
    }
    // The current one: never a wrong automatic match, and it finds them all.
    expect(scores['5. v0.14.1 + rapidfuzz']!.wrongMatch, 0);
    expect(scores['5. v0.14.1 + rapidfuzz']!.missed, 0);
  });
}
