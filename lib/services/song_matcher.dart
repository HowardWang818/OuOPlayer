import 'dart:math';

/// How sure [SongMatcher] is that two songs are the same.
enum MatchLevel {
  /// Not the same song.
  no,

  /// Probably the same: shown to the user to confirm, never used on its own.
  maybe,

  /// The same song: used without asking.
  sure,
}

class MatchResult {
  const MatchResult(this.level, this.score);
  final MatchLevel level;

  /// 0–1, higher is closer.
  final double score;

  static const none = MatchResult(MatchLevel.no, 0);
}

/// Folds width, case, spacing and punctuation: 「ＹＯＡＳＯＢＩ：群青！」→「yoasobi群青」.
String foldText(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    var c = r;
    if (c >= 0xFF01 && c <= 0xFF5E) c -= 0xFEE0; // full-width ASCII
    if (c == 0x3000) c = 0x20;
    b.writeCharCode(c);
  }
  return b.toString().toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
}

bool _isCjk(String s) => RegExp(r'[぀-ヿ㐀-鿿가-힯]').hasMatch(s);

/// Long enough for a 「starts with」 or 「contains」 match to mean something.
bool _longEnough(String folded) => _isCjk(folded) ? folded.runes.length >= 2 : folded.length >= 4;

// 「Official Music Video」, 「MV」, 「中文字幕」… — words that are about the upload,
// not the song.
final _noise = RegExp(
  r'(official\s*)?(music\s*)?(video|audio|lyric\s*video|lyrics?|visuali[sz]er|mv|pv|m/v)\b'
  r'|\b(hd|hq|4k|1080p|720p|explicit|clean|remaster(ed)?(\s*\d{4})?|tv\s*size|full\s*ver(sion)?\.?|short\s*ver(sion)?\.?|ver\.)\b'
  r'|中文字幕|中日字幕|動態歌詞|歌詞版?|字幕|官方|完整版|高音質|無損|主題曲|片頭曲|片尾曲|插曲|オフィシャル|歌ってみた|フル',
  caseSensitive: false,
);

final _quoted = RegExp(r'《(.+?)》|「(.+?)」|『(.+?)』|〈(.+?)〉|“(.+?)”|"(.+?)"');
final _bracketed = RegExp(r'[\(（\[【［<＜].*?[\)）\]】］>＞]');
final _feat = RegExp(r'\s(feat\.?|ft\.?|featuring|with)\s.*$', caseSensitive: false);
final _separators = RegExp(r'\s+[-–—~|｜／/:：]\s+|\s*[|｜／]\s*|\s+/\s*|\s*/\s+');

/// A channel or credit as artist names: 「韋禮安 WeiBird」→ [韋禮安, weibird];
/// 「YOASOBI - Topic」→ [yoasobi]; 「A feat. B」→ [a, b].
List<String> artistNames(String raw) {
  var s = raw
      .replaceAll(RegExp(r'\s*-\s*topic$', caseSensitive: false), '')
      .replaceAll(RegExp(r'\b(vevo|official|channel|music)\b|オフィシャル|官方頻道|官方', caseSensitive: false), ' ');
  final names = <String>{};
  for (final part in s.split(RegExp(r'\s*(,|;|&|、|×|\bx\b|/|／|\bfeat\.?|\bft\.?|\bwith\b|\band\b)\s*', caseSensitive: false))) {
    final p = part.trim();
    if (p.isEmpty) continue;
    names.add(foldText(p));
    // Bilingual names: the CJK and Latin halves each count on their own.
    final cjk = p.replaceAll(RegExp(r'[A-Za-z0-9 .\x27\-]+'), ' ').trim();
    final latin = p.replaceAll(RegExp(r'[^A-Za-z0-9 .\x27\-]+'), ' ').trim();
    if (cjk.isNotEmpty && latin.isNotEmpty) {
      names.add(foldText(cjk));
      names.add(foldText(latin));
    }
  }
  names.removeWhere((n) => n.isEmpty || n == foldText('未知演出者'));
  return names.toList();
}

/// The likely song titles hidden in an upload title (folded), best first:
/// 「韋禮安 WeiBird《如果可以 Red Scarf》MV - 電影「月老」主題曲」→ 如果可以redscarf, …
/// [artists] (folded) are removed when the title carries them.
List<String> titleCandidates(String raw, {List<String> artists = const []}) {
  final out = <String>[];
  void add(String s) {
    var f = foldText(s.replaceAll(_noise, ' '));
    for (final a in artists) {
      if (a.isEmpty || f == a) continue;
      if (f.startsWith(a) && f.length > a.length) f = f.substring(a.length);
      if (f.endsWith(a) && f.length > a.length) f = f.substring(0, f.length - a.length);
    }
    if (f.isNotEmpty && !artists.contains(f) && !out.contains(f)) out.add(f);
  }

  // Text in 《》「」… is usually the title itself.
  for (final m in _quoted.allMatches(raw)) {
    add(m.groups(List.generate(m.groupCount, (i) => i + 1)).firstWhere((g) => g != null)!);
  }
  final plain = raw.replaceAll(_quoted, ' ').replaceAll(_bracketed, ' ').replaceAll(_feat, '');
  final parts = plain.split(_separators).map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
  for (final p in parts) {
    add(p);
  }
  add(raw.replaceAll(_bracketed, ' ').replaceAll(_feat, ''));
  add(raw);
  return out;
}

/// Edit distance (insert, delete, replace), on runes.
int editDistance(String a, String b) {
  final x = a.runes.toList(), y = b.runes.toList();
  if (x.isEmpty) return y.length;
  if (y.isEmpty) return x.length;
  var prev = List<int>.generate(y.length + 1, (i) => i);
  for (var i = 1; i <= x.length; i++) {
    final cur = List<int>.filled(y.length + 1, 0)..[0] = i;
    for (var j = 1; j <= y.length; j++) {
      cur[j] = min(min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1));
    }
    prev = cur;
  }
  return prev[y.length];
}

/// How alike two folded titles are (0–1).
double titleSimilarity(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 1;
  final shorter = a.length <= b.length ? a : b, longer = a.length <= b.length ? b : a;
  // 「如果可以」 and 「如果可以 Red Scarf」: the same song with its title in a
  // second script. Not 「Love」 and 「Love Story」, or 「如果」 and 「如果可以」.
  if (_longEnough(shorter) && longer.startsWith(shorter) && _isCjk(longer.substring(shorter.length)) != _isCjk(shorter)) {
    return 0.92;
  }
  final ratio = 1 - editDistance(a, b) / max(a.runes.length, b.runes.length);
  // Small typos only count on titles long enough to have them.
  return shorter.runes.length >= (_isCjk(shorter) ? 4 : 6) ? ratio : (ratio == 1 ? 1 : 0);
}

/// One song as the matcher sees it.
class SongKey {
  SongKey(this.title, this.artist, {this.durationMs})
      : artists = artistNames(artist),
        foldedTitle = foldText(title) {
    titles = titleCandidates(title, artists: artists);
  }

  final String title;
  final String artist;
  final int? durationMs;
  final List<String> artists;
  final String foldedTitle;
  late final List<String> titles;

  bool get artistKnown => artists.isNotEmpty;
}

/// The one place OuOPlayer decides whether two songs are the same: imports
/// (Spotify, M3U), restoring a backup, skipping downloads that are already
/// there, and filling in missing playlist songs.
class SongMatcher {
  /// Same artist: one of the names equal, or one containing the other, or
  /// the artist named in the other song's title (「YOASOBI - 群青 / THE FIRST TAKE」).
  static bool sameArtist(SongKey a, SongKey b) {
    for (final x in a.artists) {
      for (final y in b.artists) {
        if (x == y) return true;
        final s = x.length <= y.length ? x : y, l = x.length <= y.length ? y : x;
        if (_longEnough(s) && l.contains(s)) return true;
      }
    }
    for (final (x, other) in [(a, b), (b, a)]) {
      for (final name in x.artists) {
        if (_longEnough(name) && other.foldedTitle.contains(name)) return true;
      }
    }
    return false;
  }

  static MatchResult compare(SongKey a, SongKey b) {
    var best = 0.0;
    for (final x in a.titles) {
      for (final y in b.titles) {
        best = max(best, titleSimilarity(x, y));
        if (best == 1) break;
      }
    }
    if (best < 0.7) return MatchResult.none;
    var score = best;
    final da = a.durationMs, db = b.durationMs;
    if (da != null && db != null && da > 0 && db > 0) {
      final diff = (da - db).abs();
      if (diff <= 3000) {
        score = min(1, score + 0.05);
      } else if (diff > 20000) {
        score -= 0.2; // a live take, an extended mix…
      }
    }
    if (a.artistKnown && b.artistKnown) {
      // Same title by another artist is another song (natori's / 9Lana's 「propose」).
      if (!sameArtist(a, b)) return MatchResult(MatchLevel.no, score);
      if (score >= 0.88) return MatchResult(MatchLevel.sure, score);
      return MatchResult(score >= 0.75 ? MatchLevel.maybe : MatchLevel.no, score);
    }
    // One side has no artist: never sure.
    return MatchResult(score >= 0.9 ? MatchLevel.maybe : MatchLevel.no, score);
  }

  /// The best of [candidates] for [song], with how sure it is.
  static (T?, MatchResult) best<T>(SongKey song, Iterable<T> candidates, SongKey Function(T) keyOf) {
    T? found;
    var result = MatchResult.none;
    for (final c in candidates) {
      final r = compare(song, keyOf(c));
      if (r.level.index > result.level.index || (r.level == result.level && r.score > result.score)) {
        found = c;
        result = r;
      }
    }
    return result.level == MatchLevel.no ? (null, result) : (found, result);
  }

  /// The cleaned title to search for (lyrics, YouTube Music): the first
  /// candidate, in its original spelling where possible.
  static String searchTitle(String title, String artist) {
    final quoted = _quoted.firstMatch(title);
    if (quoted != null) {
      final q = quoted.groups(List.generate(quoted.groupCount, (i) => i + 1)).firstWhere((g) => g != null)!;
      return q.replaceAll(_noise, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    }
    final names = artistNames(artist);
    final plain = title.replaceAll(_bracketed, ' ').replaceAll(_feat, '').replaceAll(_noise, ' ');
    final parts = plain.split(_separators).map((p) => p.trim()).where((p) => p.isNotEmpty && !names.contains(foldText(p))).toList();
    final t = (parts.isEmpty ? plain : parts.first).replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.isEmpty ? title : t;
  }

  /// The first artist name in its original spelling, without channel words.
  static String searchArtist(String artist) => artist
      .replaceAll(RegExp(r'\s*-\s*topic$', caseSensitive: false), '')
      .split(RegExp(r'\s*(,|;|&|、|×|/|\bfeat\.?|\bft\.?)\s*', caseSensitive: false))
      .first
      .trim();
}

/// Library songs indexed for fast lookups: only songs sharing a title word
/// are compared, so big libraries stay quick.
class SongIndex<T> {
  SongIndex(Iterable<T> items, this.keyOf) {
    for (final it in items) {
      final k = keyOf(it);
      _keys[it] = k;
      for (final t in k.titles) {
        for (final g in _grams(t)) {
          _byGram.putIfAbsent(g, () => <T>{}).add(it);
        }
      }
    }
  }

  final SongKey Function(T) keyOf;
  final _keys = <T, SongKey>{};
  final _byGram = <String, Set<T>>{};

  /// Two-letter pieces (one for CJK) of a folded title.
  static Iterable<String> _grams(String s) sync* {
    final r = s.runes.toList();
    if (r.isEmpty) return;
    if (r.length == 1) {
      yield s;
      return;
    }
    for (var i = 0; i + 1 < r.length; i++) {
      yield String.fromCharCodes([r[i], r[i + 1]]);
    }
  }

  (T?, MatchResult) find(SongKey song) {
    final pool = <T>{};
    for (final t in song.titles) {
      for (final g in _grams(t)) {
        pool.addAll(_byGram[g] ?? const {});
      }
    }
    return SongMatcher.best(song, pool, (it) => _keys[it]!);
  }
}
