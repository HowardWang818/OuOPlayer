import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../data/db/database.dart';
import '../data/models/track.dart';
import 'lyrics/lyrics_service.dart' show hasKana;
import 'native_names.dart';
import 'online/itunes.dart';
import 'song_matcher.dart';

/// An official cover found for a song.
class CoverHit {
  const CoverHit(this.track, this.song, this.level);
  final Track track;
  final ITunesSong song;

  /// [MatchLevel.sure] are ticked by default; [MatchLevel.maybe] ones aren't.
  final MatchLevel level;

  /// At [CoverFinder.size] (iTunes serves any size from the same path).
  String get url => song.artwork!.replaceFirst('600x600bb', '${CoverFinder.size}x${CoverFinder.size}bb');
}

/// Width and height of a JPEG / PNG file (from its header), or null.
(int, int)? imageSize(String path) {
  try {
    final f = File(path).openSync();
    try {
      final b = f.readSync(64 * 1024);
      if (b.length > 24 && b[0] == 0x89 && b[1] == 0x50) {
        int be32(int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
        return (be32(16), be32(20));
      }
      if (b.length > 4 && b[0] == 0xFF && b[1] == 0xD8) {
        var i = 2;
        while (i + 9 < b.length) {
          if (b[i] != 0xFF) return null;
          final marker = b[i + 1];
          final len = (b[i + 2] << 8) | b[i + 3];
          // SOF0–SOF15 except DHT / JPG / DAC hold the frame size.
          if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
            return ((b[i + 7] << 8) | b[i + 8], (b[i + 5] << 8) | b[i + 6]);
          }
          i += 2 + len;
        }
      }
    } finally {
      f.closeSync();
    }
  } catch (_) {}
  return null;
}

/// Finds square album covers on iTunes (free, no key) for songs whose title
/// and artist SongMatcher can confirm. Results of one album are reused, and
/// lookups are spaced out (iTunes allows about 20 a minute).
class CoverFinder {
  CoverFinder(this._search, {Dio? dio, this.pause = const Duration(seconds: 3), this.japaneseLyrics})
      : _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 15), receiveTimeout: const Duration(seconds: 30)));

  final ITunesSearch _search;
  final Dio _dio;
  final Duration pause;

  /// Whether a song's lyrics are Japanese (see [storesFor]).
  final Future<bool> Function(Track)? japaneseLyrics;
  final _byAlbum = <String, ITunesSong>{};

  /// Songs worth looking up: online-free local/downloaded songs that have no
  /// cover, or a YouTube download's thumbnail (usually not square).
  static bool wantsCover(Track t) =>
      (t.source == TrackSource.local || t.source == TrackSource.download) && (t.art == null || t.source == TrackSource.download);

  /// Cover size 找封面 asks for (設定 → 音樂庫 → 封面大小, 'cover_size').
  static int size = 1200;
  static const sizes = [600, 1200, 3000];

  /// Reads the 封面大小 setting.
  static Future<void> loadSize(AppDatabase db) async {
    final v = int.tryParse((await db.allSettings())['cover_size'] ?? '');
    size = sizes.contains(v) ? v! : 1200;
  }

  /// A cover smaller than 500×500 (blurry on a computer screen).
  static bool smallCover(Track t) {
    if (t.source != TrackSource.local && t.source != TrackSource.download) return false;
    final a = t.art;
    if (a == null || a.startsWith('http')) return false;
    final size = imageSize(a);
    return size != null && (size.$1 < 500 || size.$2 < 500);
  }

  /// Stores tried in turn: the device's own (its names), then Japan (Japanese
  /// songs keep their Japanese names there; the Taiwanese store gives many in
  /// romaji), then the US.
  static List<String> get stores => {ITunesSearch.country, 'JP', 'US'}.toList();

  /// [stores], Japan first for a Japanese song: elsewhere it's easily a cover
  /// version by someone else.
  static List<String> storesFor({required bool japanese}) => japanese ? {'JP', ...stores}.toList() : stores;

  /// The best iTunes song for [t], or null.
  Future<CoverHit?> find(Track t) async {
    final albumKey = t.album == '未知專輯' ? null : '${foldText(t.album)}|${foldText(t.artist)}';
    final cached = albumKey == null ? null : _byAlbum[albumKey];
    if (cached != null) return CoverHit(t, cached, MatchLevel.sure);
    final artist = t.artist == '未知演出者' ? '' : SongMatcher.searchArtist(t.artist);
    final query = [SongMatcher.searchTitle(t.title, t.artist), artist].where((s) => s.isNotEmpty).join(' ');
    final order = storesFor(japanese: hasKana('${t.title} ${t.artist}') || (await japaneseLyrics?.call(t) ?? false));
    CoverHit? maybe;
    for (final (i, store) in order.indexed) {
      if (i > 0) await Future.delayed(pause);
      final (song, result) = pick(t, await _search.search(query, limit: 15, store: store));
      if (song == null) continue;
      if (result.level == MatchLevel.sure) {
        if (albumKey != null) _byAlbum[albumKey] = song;
        return CoverHit(t, song, result.level);
      }
      maybe ??= CoverHit(t, song, result.level);
    }
    if (maybe != null) return maybe;
    // Not found by its title: its album's cover (album name + artist).
    if (albumKey == null || artist.isEmpty) return null;
    for (final store in order) {
      await Future.delayed(pause);
      final album = pickAlbum(t, await _search.search('${t.album} $artist', limit: 15, store: store));
      if (album != null) {
        _byAlbum[albumKey] = album;
        return CoverHit(t, album, MatchLevel.sure);
      }
    }
    return null;
  }

  /// A song of the same album (name) by the same artist: its artwork is the album's.
  @visibleForTesting
  static ITunesSong? pickAlbum(Track t, List<ITunesSong> results) {
    final album = foldText(t.album.replaceAll(RegExp(r'\s+-\s+(Single|EP)$'), ''));
    return results
        .where((r) =>
            r.artwork != null &&
            foldText(r.album.replaceAll(RegExp(r'\s+-\s+(Single|EP)$'), '')) == album &&
            SongMatcher.sameArtist(SongKey(t.title, t.artist), SongKey(r.title, r.artist)))
        .firstOrNull;
  }

  @visibleForTesting
  static (ITunesSong?, MatchResult) pick(Track t, List<ITunesSong> results) => SongMatcher.best(
        SongKey(t.title, t.artist, durationMs: t.durationMs),
        // Covers, piano / music-box versions and live takes carry their own artwork.
        results.where((r) => r.artwork != null && !isOtherVersion('${r.title} ${r.artist}', t.title)),
        (r) => SongKey(r.title, r.artist, durationMs: r.durationMs),
      );

  /// Looks up [tracks] one after another; [onHit] gets each result (null
  /// when nothing fits). Stops when [cancelled] returns true.
  Future<void> findAll(List<Track> tracks, void Function(Track, CoverHit?) onHit,
      {bool Function()? cancelled, bool Function()? paused}) async {
    for (var i = 0; i < tracks.length; i++) {
      while ((paused?.call() ?? false) && !(cancelled?.call() ?? false)) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
      if (cancelled?.call() ?? false) return;
      CoverHit? hit;
      try {
        hit = await find(tracks[i]);
      } catch (_) {}
      onHit(tracks[i], hit);
      if (i < tracks.length - 1) await Future.delayed(pause);
    }
  }

  Future<Uint8List> download(String url) async {
    final res = await _dio.get<List<int>>(url, options: Options(responseType: ResponseType.bytes));
    return Uint8List.fromList(res.data ?? const []);
  }
}
