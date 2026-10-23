import 'dart:io';

import 'package:path/path.dart' as p;

import 'library_scanner.dart';

/// Key for the download history: the video id for YouTube (so watch?v=,
/// youtu.be and music.youtube.com links match), otherwise the URL itself.
String sourceKey(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return url.trim();
  final host = uri.host.toLowerCase();
  if (host.endsWith('youtu.be') && uri.pathSegments.isNotEmpty) return 'youtube:${uri.pathSegments.first}';
  if (host.endsWith('youtube.com')) {
    final v = uri.queryParameters['v'];
    if (v != null && v.isNotEmpty) return 'youtube:$v';
    if (uri.pathSegments.length >= 2 && uri.pathSegments.first == 'shorts') return 'youtube:${uri.pathSegments[1]}';
  }
  return url.trim();
}

/// A link to a whole playlist (not a single song that happens to carry a
/// list, like YouTube's watch?v=…&list=…).
bool isPlaylistUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return false;
  final host = uri.host.toLowerCase();
  final path = uri.path.toLowerCase();
  if (host.endsWith('youtube.com')) {
    return path == '/playlist' || (uri.queryParameters.containsKey('list') && !uri.queryParameters.containsKey('v') && !path.startsWith('/shorts'));
  }
  return path.contains('/playlist') || path.contains('/sets/') || path.contains('/album/');
}

/// Letters and digits only, lower-case: yt-dlp swaps characters that aren't
/// allowed in file names (e.g. "/" → "⧸", "?" → "？"), so punctuation can't be
/// compared directly.
String normalizeName(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

/// A channel or uploader name used as the artist: YouTube Music's
/// auto-generated "Artist - Topic" channels lose the suffix.
String? cleanArtist(String? s) {
  var t = (s ?? '').trim();
  if (t.endsWith(' - Topic')) t = t.substring(0, t.length - ' - Topic'.length).trim();
  return t.isEmpty ? null : t;
}

/// Same artist despite spacing and punctuation, or one credit containing
/// the other ("YOASOBI" and "Ayase / YOASOBI").
bool sameArtist(String a, String b) {
  final x = normalizeName(a);
  final y = normalizeName(b);
  if (x.isEmpty || y.isEmpty) return false;
  return x == y || x.contains(y) || y.contains(x);
}

/// Audio files already in the download folder, looked up by song title.
class ExistingFiles {
  ExistingFiles(Map<String, List<String>> byName) : _byName = byName;
  final Map<String, List<String>> _byName;

  static Future<ExistingFiles> scan(String dir) async {
    final map = <String, List<String>>{};
    final d = Directory(dir);
    if (await d.exists()) {
      await for (final f in d.list(followLinks: false)) {
        if (f is! File || !audioExtensions.contains(p.extension(f.path).toLowerCase())) continue;
        final key = normalizeName(p.basenameWithoutExtension(f.path));
        if (key.isNotEmpty) map.putIfAbsent(key, () => []).add(f.path);
      }
    }
    return ExistingFiles(map);
  }

  /// The first file [candidates] finds for [title].
  String? match(String title) => candidates(title).firstOrNull;

  /// Files yt-dlp may have made for [title], in any audio format: named
  /// after the title, or 「title - artist」 when another artist's song had
  /// the name already. Long titles are cut to 150 bytes in file names, so a
  /// long file name that the title starts with also counts. Same title
  /// doesn't mean same song: check the artist too.
  List<String> candidates(String title, [String? artist]) {
    final key = normalizeName(title);
    if (key.isEmpty) return const [];
    return [
      ...?_byName[key],
      if (artist != null) ...?_byName[normalizeName('$title - $artist')],
      for (final e in _byName.entries)
        if (e.key != key && e.key.length >= 30 && key.startsWith(e.key)) ...e.value,
    ];
  }
}
