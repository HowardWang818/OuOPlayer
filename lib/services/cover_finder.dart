import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../data/models/track.dart';
import 'online/itunes.dart';
import 'song_matcher.dart';

/// An official cover found for a song.
class CoverHit {
  const CoverHit(this.track, this.song, this.level);
  final Track track;
  final ITunesSong song;

  /// [MatchLevel.sure] are ticked by default; [MatchLevel.maybe] ones aren't.
  final MatchLevel level;
  String get url => song.artwork!;
}

/// Finds square album covers on iTunes (free, no key) for songs whose title
/// and artist SongMatcher can confirm. Results of one album are reused, and
/// lookups are spaced out (iTunes allows about 20 a minute).
class CoverFinder {
  CoverFinder(this._search, {Dio? dio, this.pause = const Duration(seconds: 3)})
      : _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 15), receiveTimeout: const Duration(seconds: 30)));

  final ITunesSearch _search;
  final Dio _dio;
  final Duration pause;
  final _byAlbum = <String, ITunesSong>{};

  /// Songs worth looking up: online-free local/downloaded songs that have no
  /// cover, or a YouTube download's thumbnail (usually not square).
  static bool wantsCover(Track t) =>
      (t.source == TrackSource.local || t.source == TrackSource.download) && (t.art == null || t.source == TrackSource.download);

  /// The best iTunes song for [t], or null.
  Future<CoverHit?> find(Track t) async {
    final albumKey = t.album == '未知專輯' ? null : '${foldText(t.album)}|${foldText(t.artist)}';
    final cached = albumKey == null ? null : _byAlbum[albumKey];
    if (cached != null) return CoverHit(t, cached, MatchLevel.sure);
    final artist = t.artist == '未知演出者' ? '' : SongMatcher.searchArtist(t.artist);
    final query = [SongMatcher.searchTitle(t.title, t.artist), artist].where((s) => s.isNotEmpty).join(' ');
    final results = await _search.search(query, limit: 15);
    final (song, result) = pick(t, results);
    if (song == null) return null;
    if (albumKey != null && result.level == MatchLevel.sure) _byAlbum[albumKey] = song;
    return CoverHit(t, song, result.level);
  }

  @visibleForTesting
  static (ITunesSong?, MatchResult) pick(Track t, List<ITunesSong> results) => SongMatcher.best(
        SongKey(t.title, t.artist, durationMs: t.durationMs),
        results.where((r) => r.artwork != null),
        (r) => SongKey(r.title, r.artist, durationMs: r.durationMs),
      );

  /// Looks up [tracks] one after another; [onHit] gets each result (null
  /// when nothing fits). Stops when [cancelled] returns true.
  Future<void> findAll(List<Track> tracks, void Function(Track, CoverHit?) onHit, {bool Function()? cancelled}) async {
    for (var i = 0; i < tracks.length; i++) {
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
