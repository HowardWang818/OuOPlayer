import 'dart:convert';

import '../ytdlp/ytdlp_downloader.dart';
import 'ytmusic.dart';

/// Where 線上搜尋 looks (the user picks; nothing is preferred).
enum OnlineSource {
  ytMusic('YT Music'),
  youtube('YouTube'),
  soundcloud('SoundCloud');

  const OnlineSource(this.label);
  final String label;

  static const key = 'online_source';

  static OnlineSource? byName(String? name) => values.where((s) => s.name == name).firstOrNull;

  /// yt-dlp's search for this source (YT Music has its own, faster one).
  String? get ytdlpPrefix => switch (this) {
        OnlineSource.ytMusic => null,
        OnlineSource.youtube => 'ytsearch20',
        OnlineSource.soundcloud => 'scsearch20',
      };
}

/// Songs from yt-dlp's `--flat-playlist -J` search answer.
List<YtMusicSong> parseYtdlpSearch(String output) {
  final start = output.indexOf('{');
  final end = output.lastIndexOf('}');
  if (start < 0 || end <= start) return const [];
  final Map j;
  try {
    j = jsonDecode(output.substring(start, end + 1)) as Map;
  } catch (_) {
    return const [];
  }
  final out = <YtMusicSong>[];
  for (final e in (j['entries'] as List? ?? const []).whereType<Map>()) {
    final url = e['webpage_url'] as String? ?? e['url'] as String?;
    final title = '${e['title'] ?? ''}'.trim();
    if (url == null || title.isEmpty) continue;
    final thumbs = (e['thumbnails'] as List?)?.whereType<Map>().toList() ?? const [];
    final dur = e['duration'];
    out.add(YtMusicSong(
      videoId: '${e['id'] ?? url}',
      title: title,
      artist: '${e['uploader'] ?? e['channel'] ?? ''}'.trim(),
      durationMs: dur is num ? (dur * 1000).round() : null,
      artwork: thumbs.isEmpty ? null : '${thumbs.last['url']}',
      link: url,
    ));
  }
  return out;
}

/// 線上搜尋 on [source]: YT Music directly, the others through yt-dlp.
Future<List<YtMusicSong>> searchOnline(OnlineSource source, String query, YtDlpBackend? ytdlp) async {
  final prefix = source.ytdlpPrefix;
  if (prefix == null) return YtMusicSearch().search(query);
  if (ytdlp == null) return const [];
  if (!await ytdlp.isReady()) await ytdlp.prepare((_) {});
  String? output;
  final lines = <String>[];
  await for (final e in ytdlp.run('search_${DateTime.now().microsecondsSinceEpoch}', '$prefix:$query', const ['--flat-playlist', '-J'])) {
    if (e is YtDlpLog) lines.add(e.line);
    if (e is YtDlpFinished) output = e.output;
  }
  return parseYtdlpSearch(output != null && output.trim().isNotEmpty ? output : lines.join('\n'));
}
