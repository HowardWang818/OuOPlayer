import 'package:dio/dio.dart';
import '../song_matcher.dart';

/// A song found on YouTube Music.
class YtMusicSong {
  const YtMusicSong({required this.videoId, required this.title, required this.artist, this.album, this.durationMs, this.artwork, this.link});
  final String videoId;

  /// The page to download (YouTube, SoundCloud); YT Music's when null.
  final String? link;
  final String title;
  final String artist;
  final String? album;
  final int? durationMs;
  final String? artwork;

  String get url => link ?? 'https://music.youtube.com/watch?v=$videoId';
}

/// Searches YouTube Music's songs the way its web player does (no key).
class YtMusicSearch {
  YtMusicSearch({Dio? dio}) : _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 15), receiveTimeout: const Duration(seconds: 20)));
  final Dio _dio;

  static const _endpoint = 'https://music.youtube.com/youtubei/v1/search?prettyPrint=false';

  /// The "songs" filter of the search page.
  static const _songsOnly = 'EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D';

  /// Japanese names (kana) are searched in Japanese: in Taiwan's locale YT
  /// Music gives Japanese songs romanised titles and artists ("Rokudenashi"
  /// for ロクデナシ), while karaoke and cover uploads keep the Japanese.
  static String localeFor(String text) => RegExp(r'[\u3040-\u30ff\u31f0-\u31ff]').hasMatch(text) ? 'ja' : 'zh-TW';

  Future<List<YtMusicSong>> search(String query, {String? hl}) async {
    final lang = hl ?? localeFor(query);
    final res = await _dio.post<Map<String, dynamic>>(
      _endpoint,
      data: {
        'context': {
          'client': {'clientName': 'WEB_REMIX', 'clientVersion': '1.20241106.01.00', 'hl': lang, 'gl': lang == 'ja' ? 'JP' : 'TW'},
        },
        'query': query,
        'params': _songsOnly,
      },
      options: Options(headers: {'Origin': 'https://music.youtube.com', 'User-Agent': 'Mozilla/5.0'}),
    );
    return parse(res.data ?? const {});
  }

  /// One song ([title] by [artist]): searched in the locale its names call
  /// for, then in the other when that finds nothing sure. The results come
  /// originals first, for picking by hand.
  Future<({YtMusicSong? sure, List<YtMusicSong> results})> find(String title, String artist, int? durationMs, String query) async {
    final first = localeFor('$title $artist');
    final a = await search(query, hl: first);
    final sa = sureMatch(title, artist, durationMs, a);
    if (sa != null) return (sure: sa, results: originalsFirst(title, artist, a));
    List<YtMusicSong> b = const [];
    try {
      b = await search(query, hl: first == 'ja' ? 'zh-TW' : 'ja');
    } catch (_) {
      if (a.isEmpty) rethrow;
    }
    final sb = sureMatch(title, artist, durationMs, b);
    return (sure: sb, results: originalsFirst(title, artist, sb != null || a.isEmpty ? b : a));
  }

  /// The best match for a song, or null.
  Future<YtMusicSong?> first(String query) async => (await search(query)).firstOrNull;

  /// The songs in a search response.
  static List<YtMusicSong> parse(Map<String, dynamic> json) {
    final out = <YtMusicSong>[];
    void walk(Object? node) {
      if (node is Map) {
        final item = node['musicResponsiveListItemRenderer'];
        if (item is Map) {
          final song = _song(item);
          if (song != null) out.add(song);
          return;
        }
        node.values.forEach(walk);
      } else if (node is List) {
        node.forEach(walk);
      }
    }

    walk(json['contents']);
    return out;
  }

  static final _time = RegExp(r'^(\d+):(\d{2})(?::(\d{2}))?$');

  static YtMusicSong? _song(Map item) {
    final id = (item['playlistItemData'] as Map?)?['videoId'] as String?;
    final columns = item['flexColumns'] as List? ?? const [];
    List<String> runs(int i) {
      if (columns.length <= i) return const [];
      final text = ((columns[i] as Map)['musicResponsiveListItemFlexColumnRenderer'] as Map?)?['text'] as Map?;
      return [for (final r in (text?['runs'] as List? ?? const [])) '${(r as Map)['text']}'];
    }

    final title = runs(0).join().trim();
    if (id == null || title.isEmpty) return null;
    // 「歌手 • 專輯 • 3:21」: groups between the bullets.
    final groups = <String>[''];
    for (final r in runs(1)) {
      if (r.trim() == '•') {
        groups.add('');
      } else {
        groups[groups.length - 1] += r;
      }
    }
    final parts = groups.map((g) => g.trim()).where((g) => g.isNotEmpty).toList();
    int? ms;
    if (parts.isNotEmpty) {
      final m = _time.firstMatch(parts.last);
      if (m != null) {
        final a = int.parse(m.group(1)!), b = int.parse(m.group(2)!), c = m.group(3) == null ? null : int.parse(m.group(3)!);
        ms = (c == null ? a * 60 + b : a * 3600 + b * 60 + c) * 1000;
        parts.removeLast();
      }
    }
    final thumbs = (((item['thumbnail'] as Map?)?['musicThumbnailRenderer'] as Map?)?['thumbnail'] as Map?)?['thumbnails'] as List?;
    var art = thumbs == null || thumbs.isEmpty ? null : '${(thumbs.last as Map)['url']}';
    // Larger square cover than the list's 120 px one.
    if (art != null) art = art.replaceFirst(RegExp(r'=w\d+-h\d+'), '=w544-h544');
    return YtMusicSong(
      videoId: id,
      title: title,
      artist: parts.isEmpty ? '' : parts.first,
      album: parts.length > 1 ? parts[1] : null,
      durationMs: ms,
      artwork: art,
    );
  }
}

/// 缺少的歌曲: the search result that is surely [title] by [artist] (same
/// artist, title close enough, length within 10 seconds when both are
/// known), or null when none is sure.
/// Karaoke, covers, live / acoustic takes are never sure unless asked for by
/// name, and the artist has to be the song's (not just named in the title).
YtMusicSong? sureMatch(String title, String artist, int? durationMs, List<YtMusicSong> results) {
  final want = SongKey(title, artist, durationMs: durationMs);
  final candidates = [
    for (final s in results)
      if (sameVersion(title, s.title) && SongMatcher.sameArtistField(want, SongKey(s.title, s.artist))) s,
  ];
  final (song, result) = SongMatcher.best(want, candidates, (YtMusicSong s) => SongKey(s.title, s.artist, durationMs: s.durationMs));
  if (song == null || result.level != MatchLevel.sure) return null;
  if (durationMs != null && song.durationMs != null && (durationMs - song.durationMs!).abs() > 10000) return null;
  return song;
}

/// [found] is the same take as [wanted]: the same version marks.
bool sameVersion(String wanted, String found) {
  final a = versionMarks(wanted), b = versionMarks(found);
  return a.length == b.length && a.containsAll(b);
}

/// 選擇版本: the song's own artist and take first, then its artist's other
/// takes, then everyone else's (otherwise in YT Music's order).
List<YtMusicSong> originalsFirst(String title, String artist, List<YtMusicSong> results) {
  final want = SongKey(title, artist);
  int rank(YtMusicSong s) {
    final mine = SongMatcher.sameArtistField(want, SongKey(s.title, s.artist));
    return mine && sameVersion(title, s.title) ? 0 : (mine ? 1 : 2);
  }

  final indexed = [for (var i = 0; i < results.length; i++) (i, rank(results[i]), results[i])]
    ..sort((x, y) => x.$2 != y.$2 ? x.$2.compareTo(y.$2) : x.$1.compareTo(y.$1));
  return [for (final x in indexed) x.$3];
}
