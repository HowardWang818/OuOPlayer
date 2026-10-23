import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../data/models/track.dart';
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
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
              headers: {'User-Agent': 'OuOPlayer (personal music player)'},
            ));

  final LibraryScanner _scanner;
  final Dio _dio;
  static const _api = 'https://lrclib.net/api';

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
        // An empty entry remembers "LRCLIB has nothing", so it isn't asked again.
        if (j['none'] == true) return null;
        return Lyrics.parse(j['lrc'] as String, source: j['source'] as String? ?? 'LRCLIB');
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

  /// LRCLIB search for the manual 「手動搜尋」 dialog.
  Future<List<LrclibResult>> search(String title, String artist) async {
    final res = await _dio.get<List<dynamic>>('$_api/search', queryParameters: {
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

  Future<LrclibResult?> _lookup(Track t) async {
    final title = t.title.replaceAll('（試聽）', '').trim();
    final artist = t.artist == '未知演出者' ? '' : t.artist;
    if (artist.isNotEmpty) {
      try {
        final res = await _dio.get<Map<String, dynamic>>('$_api/get', queryParameters: {
          'track_name': title,
          'artist_name': artist,
          if (t.album != '未知專輯') 'album_name': t.album,
          if (t.durationMs != null && t.source != TrackSource.preview) 'duration': (t.durationMs! / 1000).round(),
        });
        final r = LrclibResult.fromJson(res.data);
        if (r != null && r.hasLyrics) return r;
      } on DioException catch (e) {
        if (e.response?.statusCode != 404) rethrow;
      }
    }
    final found = await search(title, artist);
    if (found.isEmpty) return null;
    // Prefer the result closest in length, when we know the length.
    final d = t.source == TrackSource.preview ? null : t.durationMs;
    if (d != null) {
      found.sort((a, b) => ((a.durationSec ?? 0) * 1000 - d).abs().compareTo(((b.durationSec ?? 0) * 1000 - d).abs()));
    }
    return found.first;
  }

  Future<File> _cacheFile(Track t) async {
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'lyrics'));
    await dir.create(recursive: true);
    final key = md5.convert(utf8.encode('${t.title}|${t.artist}|${t.album}')).toString();
    return File(p.join(dir.path, '$key.json'));
  }

  Future<void> _save(File f, LrclibResult? r) async {
    final lrc = r == null ? null : ((r.synced ?? '').trim().isNotEmpty ? r.synced : r.plain);
    await f.writeAsString(jsonEncode(lrc == null ? {'none': true} : {'lrc': lrc, 'source': 'LRCLIB'}));
  }
}
