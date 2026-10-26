import 'package:flutter/foundation.dart';

import '../data/db/database.dart';
import '../data/models/track.dart';
import 'online/itunes.dart';
import 'song_matcher.dart';
import 'tag_editor.dart';

final _nativeChar = RegExp(r'[぀-ヿ㐀-鿿豈-﫿가-힯]');
final _latinChar = RegExp(r'[A-Za-z]');

/// Whether [s] has CJK / kana / hangul in it.
bool hasNativeText(String s) => _nativeChar.hasMatch(s);

/// Other recordings that happen to have the same length (piano and music-box
/// covers, karaoke, live takes); only taken when the song itself is one.
final otherVersion = RegExp(
    r'piano|オルゴール|music ?box|inst\b|instrumental|karaoke|カラオケ|off vocal|cover|カバー|acoustic|remix|live\b|first take|tv ?size|ver\.|version',
    caseSensitive: false);

/// Whether [found] is another recording (cover, piano, live…) of a song
/// named [own] that isn't one itself.
bool isOtherVersion(String found, String own) => otherVersion.hasMatch(found) && !otherVersion.hasMatch(own);

/// Bracketed parts of a title: 「(…)」「（…）」「[…]」「【…】」「「…」」「《…》」.
final _bracketed = RegExp(r'\s*[\(（\[【「『《][^\(（\[【「『《\)）\]】」』》]*[\)）\]】」』》]');

/// [s] without its bracketed parts, nested ones too (「光年之外 (電影《…》主題曲)」 → 「光年之外」).
String withoutBrackets(String s) {
  for (;;) {
    final next = s.replaceAll(_bracketed, '');
    if (next == s) return s.trim();
    s = next;
  }
}

/// A title's original name already given in brackets after a Latin one
/// (「Through the Night (밤편지)」 → 「밤편지」), or null.
String? bracketNative(String title) {
  if (hasNativeText(withoutBrackets(title))) return null;
  for (final m in _bracketed.allMatches(title)) {
    final inner = m[0]!.trim();
    final text = inner.substring(1, inner.length - 1).trim();
    if (hasNativeText(text) && !text.toLowerCase().contains('feat')) return text;
  }
  return null;
}

/// The original name of a song tagged in romaji or English (YouTube Music
/// downloads: 「Yoru ni Kakeru」 → 「夜に駆ける」, 「Practice Love」 → 「修煉愛情」).
class NativeName {
  const NativeName(this.track, {required this.title, required this.artist, required this.album});
  final Track track;
  final String title;
  final String artist;
  final String album;
}

/// 找原文歌名: the original name from the title's own brackets, else the
/// Japanese iTunes store, else the Taiwanese one (Chinese songs). Only a
/// release by the same artist (or one written in CJK where ours is in Latin
/// letters) within 2 s of the song's length counts; anything less certain is
/// left alone. Korean songs carry English names on iTunes, so only their
/// bracketed hangul is used.
class NativeNames {
  NativeNames(this._search, {this.pause = const Duration(seconds: 3)});

  final ITunesSearch _search;

  /// Between lookups: iTunes allows about 20 a minute.
  final Duration pause;
  Future<void> _queue = Future.value();

  /// Songs worth looking up: local / downloaded, named in Latin letters
  /// (apart from a bracketed original).
  static bool wants(Track t) {
    if (t.source != TrackSource.local && t.source != TrackSource.download) return false;
    final outside = withoutBrackets(t.title);
    return !hasNativeText(outside) && _latinChar.hasMatch(outside) && (t.durationMs != null || bracketNative(t.title) != null);
  }

  /// The original names for [t], or null (nothing certain, or already so).
  /// Lookups are queued one at a time with [pause] between them.
  Future<NativeName?> find(Track t) {
    final inBrackets = bracketNative(t.title);
    if (inBrackets != null) return Future.value(NativeName(t, title: inBrackets, artist: t.artist, album: t.album));
    final result = _queue.then((_) async {
      final artist = t.artist == '未知演出者' ? '' : SongMatcher.searchArtist(t.artist);
      final query = [SongMatcher.searchTitle(t.title, t.artist), artist].where((s) => s.isNotEmpty).join(' ');
      final jp = pick(t, await _search.search(query, limit: 15, store: 'JP'));
      if (jp != null) return jp;
      await Future.delayed(pause);
      return pick(t, await _search.search(query, limit: 15, store: 'TW'), nativeTitleOnly: true);
    });
    _queue = result.then((_) => Future.delayed(pause), onError: (_) => Future.delayed(pause));
    return result;
  }

  /// [nativeTitleOnly] (the Taiwanese store, which also gives foreign artists
  /// Chinese names: 「BTS」 → 「防彈少年團」): only a title in Chinese counts.
  @visibleForTesting
  static NativeName? pick(Track t, List<ITunesSong> results, {bool nativeTitleOnly = false}) {
    final length = t.durationMs;
    if (length == null || hasNativeText(t.title)) return null;
    final ownArtist = t.artist == '未知演出者' ? '' : t.artist;
    bool fits(ITunesSong r) {
      if (r.durationMs == null || (r.durationMs! - length).abs() > 2000) return false;
      if (isOtherVersion(r.title, t.title)) return false;
      if (ownArtist.isEmpty) return false;
      if (SongMatcher.sameArtist(SongKey(t.title, ownArtist), SongKey(r.title, r.artist))) return true;
      // The artist in Japanese where ours is romaji (「Kenshi Yonezu」 →
      // 「米津玄師」): names can't be compared, so only iTunes' top hit for
      // our title and artist counts.
      return identical(r, results.first) && hasNativeText(r.artist) && !hasNativeText(ownArtist);
    }

    final hits = results.where(fits).toList();
    // The same name in Latin letters is a release of its own (e.g. YOASOBI's
    // English 「Idol」 next to 「アイドル」): can't tell which one this is.
    final want = foldText(SongMatcher.searchTitle(t.title, ownArtist));
    if (hits.any((r) => hasNativeText(r.title)) &&
        hits.any((r) => !hasNativeText(r.title) && foldText(SongMatcher.searchTitle(r.title, r.artist)) == want)) {
      return null;
    }
    final r = hits.where((r) => hasNativeText(r.title) || (!nativeTitleOnly && hasNativeText(r.artist))).firstOrNull;
    if (r == null) return null;
    // Without notes like 「(電影《…》主題曲)」, unless the name is only in them.
    final short = withoutBrackets(r.title);
    final title = hasNativeText(short)
        ? short
        : hasNativeText(r.title) && foldText(short) != want
            ? r.title
            : t.title;
    final artist = hasNativeText(r.artist) && !hasNativeText(ownArtist) ? r.artist : t.artist;
    final ownAlbum = t.album == '未知專輯' ? '' : t.album;
    final album = hasNativeText(r.album) && !hasNativeText(ownAlbum) ? cleanAlbum(r.album) : t.album;
    if (title == t.title && artist == t.artist && album == t.album) return null;
    return NativeName(t, title: title, artist: artist, album: album);
  }

  /// 「夜に駆ける - Single」 → 「夜に駆ける」.
  static String cleanAlbum(String album) => album.replaceAll(RegExp(r'\s+-\s+(Single|EP)$'), '').trim();

  /// Renames the song: into the file's tags when its format allows (else only
  /// in OuOPlayer), then in the library. Null when the user declined the
  /// file change (Android asks for files OuOPlayer didn't create).
  static Future<Track?> apply(AppDatabase db, NativeName n) async {
    final t = n.track;
    if (canWriteTags(t.uri)) {
      final r = await writeTags(t.uri, TagEdit(title: n.title, artist: n.artist, album: n.album));
      if (r == TagWriteResult.declined) return null;
    }
    final updated = Track(
      id: t.id,
      uri: t.uri,
      title: n.title,
      artist: n.artist,
      album: n.album,
      durationMs: t.durationMs,
      art: t.art,
      source: t.source,
      trackNo: t.trackNo,
      addedAt: t.addedAt,
    );
    await db.updateTrackInfo(updated);
    return updated;
  }
}
