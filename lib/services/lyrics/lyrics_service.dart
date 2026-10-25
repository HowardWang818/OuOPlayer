import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../data/models/track.dart';
import '../song_matcher.dart';
import '../library_scanner.dart';
import 'lrc.dart';

/// A song found on LRCLIB (manual search results).
class LrclibResult {
  const LrclibResult({required this.title, required this.artist, required this.album, this.durationSec, this.synced, this.plain});
  final String title;
  final String artist;
  final String album;
  final int? durationSec;
  final String? synced;
  final String? plain;

  bool get hasLyrics => (synced ?? '').trim().isNotEmpty || (plain ?? '').trim().isNotEmpty;

  static LrclibResult? fromJson(Object? j) {
    if (j is! Map) return null;
    return LrclibResult(
      title: j['trackName'] as String? ?? '',
      artist: j['artistName'] as String? ?? '',
      album: j['albumName'] as String? ?? '',
      durationSec: (j['duration'] as num?)?.round(),
      synced: j['syncedLyrics'] as String?,
      plain: j['plainLyrics'] as String?,
    );
  }

  Lyrics toLyrics() => Lyrics.parse((synced ?? '').trim().isNotEmpty ? synced! : plain ?? '', source: 'LRCLIB');
}

/// Finds lyrics, in order: the file's own tags, a same-name .lrc next to it,
/// the local cache, then LRCLIB (lrclib.net, free, no key) if allowed.
/// Lyrics are only shown in the app; nothing is written to music files.
class LyricsService {
  LyricsService(this._scanner, {Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 30),
              headers: {'User-Agent': 'OuOPlayer (personal music player)'},
            ));

  final LibraryScanner _scanner;
  final Dio _dio;
  static const _api = 'https://lrclib.net/api';

  /// "Nothing on LRCLIB" is remembered this long, then asked again.
  static const notFoundFor = Duration(days: 3);

  /// Waits before the retries when LRCLIB is busy (it answers 503 now and
  /// then) or slow.
  static const retryDelays = [Duration(seconds: 1), Duration(seconds: 3)];

  Future<Response<T>> _get<T>(String path, Map<String, dynamic> query) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await _dio.get<T>('$_api/$path', queryParameters: query);
      } on DioException catch (e) {
        if (attempt >= retryDelays.length || !isTemporary(e)) rethrow;
        await Future.delayed(retryDelays[attempt]);
      }
    }
  }

  /// Busy server, timeouts and dropped connections: worth trying again.
  static bool isTemporary(DioException e) {
    final code = e.response?.statusCode;
    return code == 429 ||
        code == 502 ||
        code == 503 ||
        code == 504 ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.connectionError;
  }

  /// Null when nothing was found.
  Future<Lyrics?> find(Track t, {required bool online}) async {
    if (!t.isRemote) {
      final tagged = await _scanner.readLyrics(t.uri);
      if (tagged != null) {
        final l = Lyrics.parse(tagged, source: '歌曲檔案');
        if (!l.isEmpty) return l;
      }
      final lrc = File('${p.withoutExtension(t.uri)}.lrc');
      if (lrc.existsSync()) {
        try {
          final l = Lyrics.parse(await lrc.readAsString(), source: '.lrc 檔');
          if (!l.isEmpty) return l;
        } catch (_) {}
      }
    }
    final cache = await _cacheFile(t);
    if (cache.existsSync()) {
      try {
        final j = jsonDecode(await cache.readAsString()) as Map;
        // "LRCLIB has nothing" is remembered for a while, then asked again.
        if (j['none'] == true) {
          final at = DateTime.fromMillisecondsSinceEpoch((j['at'] as int?) ?? 0);
          if (DateTime.now().difference(at) < notFoundFor) return null;
        } else {
          return Lyrics.parse(j['lrc'] as String, source: j['source'] as String? ?? 'LRCLIB');
        }
      } catch (_) {}
    }
    if (!online || t.source == TrackSource.podcast) return null;
    final r = await _lookup(t);
    if (r == null || !r.hasLyrics) {
      await _save(cache, null);
      return null;
    }
    await _save(cache, r);
    return r.toLyrics();
  }

  /// Whether [t] already has lyrics on the phone: in the file, a .lrc next
  /// to it, or found on LRCLIB before.
  Future<bool> hasLyrics(Track t) async {
    if (!t.isRemote) {
      final tagged = await _scanner.readLyrics(t.uri);
      if (tagged != null && !Lyrics.parse(tagged, source: '').isEmpty) return true;
      if (File('${p.withoutExtension(t.uri)}.lrc').existsSync()) return true;
    }
    final cache = await _cacheFile(t);
    if (!cache.existsSync()) return false;
    try {
      return (jsonDecode(await cache.readAsString()) as Map)['lrc'] is String;
    } catch (_) {
      return false;
    }
  }

  /// 找歌詞 (batch, or after a download): asks LRCLIB now, even if it had
  /// nothing a short while ago, and saves what it finds. True if found.
  Future<bool> fetchOnline(Track t) async {
    final cache = await _cacheFile(t);
    final r = await _lookup(t);
    if (r == null || !r.hasLyrics) {
      await _save(cache, null);
      return false;
    }
    await _save(cache, r);
    return true;
  }

  Future<void> _queue = Future.value();

  /// Looks lyrics up in the background for songs that have none, one at a
  /// time with a pause between them (new downloads). Errors are ignored:
  /// playing the song asks again later.
  void fetchLater(Track t) {
    if (t.isRemote || t.source == TrackSource.podcast) return;
    _queue = _queue.then((_) async {
      try {
        if (!await hasLyrics(t)) {
          await fetchOnline(t);
          onFetched?.call(t);
          await Future.delayed(const Duration(seconds: 1));
        }
      } catch (_) {}
    });
  }

  /// Called after [fetchLater] looked a song up (so lyrics shown refresh).
  void Function(Track)? onFetched;

  /// LRCLIB search for the manual 「手動搜尋」 dialog.
  Future<List<LrclibResult>> search(String title, String artist) async {
    final res = await _get<List<dynamic>>('search', {
      'track_name': title,
      if (artist.trim().isNotEmpty) 'artist_name': artist,
    });
    return [for (final j in res.data ?? const []) LrclibResult.fromJson(j)].whereType<LrclibResult>().where((r) => r.hasLyrics).toList();
  }

  /// Remembers the user's pick for this song.
  Future<void> choose(Track t, LrclibResult r) async => _save(await _cacheFile(t), r);

  /// Forgets a cached result (e.g. to search again after a wrong match).
  Future<void> forget(Track t) async {
    final f = await _cacheFile(t);
    if (f.existsSync()) await f.delete();
  }

  /// Exact match first; if that has no synced lyrics (LRCLIB often has a
  /// plain copy and several synced ones of the same song), search too, also
  /// with the title cleaned up and with the title alone (then the artist
  /// must match).
  Future<LrclibResult?> _lookup(Track t) async {
    final title = t.title.replaceAll('（試聽）', '').trim();
    final artist = t.artist == '未知演出者' ? '' : t.artist;
    final durationMs = t.source == TrackSource.preview ? null : t.durationMs;
    LrclibResult? exact;
    if (artist.isNotEmpty) {
      try {
        final res = await _get<Map<String, dynamic>>('get', {
          'track_name': title,
          'artist_name': artist,
          if (t.album != '未知專輯') 'album_name': t.album,
          if (durationMs != null) 'duration': (durationMs / 1000).round(),
        });
        exact = LrclibResult.fromJson(res.data);
        if (exact != null && (exact.synced ?? '').trim().isNotEmpty) return exact;
      } on DioException catch (e) {
        if (e.response?.statusCode != 404) rethrow;
      }
    }
    // Upload titles (「YOASOBI「アイドル」Official Music Video」) and channel
    // names (「YOASOBI - Topic」) cleaned the same way as everywhere else.
    final clean = SongMatcher.searchTitle(title, artist);
    final cleanArtist = artist.isEmpty ? '' : SongMatcher.searchArtist(artist);
    final found = <LrclibResult>[
      ...await search(title, artist),
      if (clean != title || cleanArtist != artist) ...await search(clean, cleanArtist),
    ];
    if (found.isEmpty && artist.isNotEmpty) {
      final me = SongKey(title, artist);
      found.addAll((await search(clean, '')).where((r) => SongMatcher.sameArtist(SongKey(r.title, r.artist), me)));
    }
    return pickBest([if (exact != null && exact.hasLyrics) exact, ...found], durationMs: durationMs);
  }

  /// Synced lyrics first, then the closest length.
  static LrclibResult? pickBest(List<LrclibResult> results, {int? durationMs}) {
    final usable = results.where((r) => r.hasLyrics).toList();
    if (usable.isEmpty) return null;
    int score(LrclibResult r) {
      final synced = (r.synced ?? '').trim().isNotEmpty ? 0 : 1 << 30;
      final off = durationMs == null || r.durationSec == null ? 0 : (r.durationSec! * 1000 - durationMs).abs();
      return synced + off;
    }

    usable.sort((a, b) => score(a).compareTo(score(b)));
    return usable.first;
  }

  /// Drops 「(Official Audio)」, 【MV】, 「feat. …」 and similar from a title.
  static String cleanSongTitle(String title) => title
      .replaceAll(RegExp(r'[\(（\[【［<＜].*?[\)）\]】］>＞]'), ' ')
      .replaceAll(RegExp(r'\s(feat\.?|ft\.)\s.*$', caseSensitive: false), '')
      .replaceAll(RegExp(r'\b(official\s+)?(music\s+)?(video|audio|mv|lyric video|lyrics)\b', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Future<File> _cacheFile(Track t) async {
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'lyrics'));
    await dir.create(recursive: true);
    final key = md5.convert(utf8.encode('${t.title}|${t.artist}|${t.album}')).toString();
    return File(p.join(dir.path, '$key.json'));
  }

  Future<void> _save(File f, LrclibResult? r) async {
    final lrc = r == null ? null : ((r.synced ?? '').trim().isNotEmpty ? r.synced : r.plain);
    await f.writeAsString(jsonEncode(
        lrc == null ? {'none': true, 'at': DateTime.now().millisecondsSinceEpoch} : {'lrc': lrc, 'source': 'LRCLIB'}));
  }
}
