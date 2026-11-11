import 'package:dio/dio.dart';

/// A song found on YouTube Music.
class YtMusicSong {
  const YtMusicSong({required this.videoId, required this.title, required this.artist, this.album, this.durationMs, this.artwork});
  final String videoId;
  final String title;
  final String artist;
  final String? album;
  final int? durationMs;
  final String? artwork;

  String get url => 'https://music.youtube.com/watch?v=$videoId';
}

/// Searches YouTube Music's songs the way its web player does (no key).
class YtMusicSearch {
  YtMusicSearch({Dio? dio}) : _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 15), receiveTimeout: const Duration(seconds: 20)));
  final Dio _dio;

  static const _endpoint = 'https://music.youtube.com/youtubei/v1/search?prettyPrint=false';

  /// The "songs" filter of the search page.
  static const _songsOnly = 'EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D';

  Future<List<YtMusicSong>> search(String query) async {
    final res = await _dio.post<Map<String, dynamic>>(
      _endpoint,
      data: {
        'context': {
          'client': {'clientName': 'WEB_REMIX', 'clientVersion': '1.20241106.01.00', 'hl': 'zh-TW', 'gl': 'TW'},
        },
        'query': query,
        'params': _songsOnly,
      },
      options: Options(headers: {'Origin': 'https://music.youtube.com', 'User-Agent': 'Mozilla/5.0'}),
    );
    return parse(res.data ?? const {});
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
