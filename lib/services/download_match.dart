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

/// Audio files already in the download folder, looked up by song title.
class ExistingFiles {
  ExistingFiles(Map<String, String> byName) : _byName = byName;
  final Map<String, String> _byName;

  static Future<ExistingFiles> scan(String dir) async {
    final map = <String, String>{};
    final d = Directory(dir);
    if (await d.exists()) {
      await for (final f in d.list(followLinks: false)) {
        if (f is! File || !audioExtensions.contains(p.extension(f.path).toLowerCase())) continue;
        final key = normalizeName(p.basenameWithoutExtension(f.path));
        if (key.isNotEmpty) map.putIfAbsent(key, () => f.path);
      }
    }
    return ExistingFiles(map);
  }

  /// The file yt-dlp would have made for [title], in any audio format.
  /// Long titles are cut to 150 bytes in file names, so a long file name
  /// that the title starts with also counts.
  String? match(String title) {
    final key = normalizeName(title);
    if (key.isEmpty) return null;
    final exact = _byName[key];
    if (exact != null) return exact;
    for (final e in _byName.entries) {
      if (e.key.length >= 30 && key.startsWith(e.key)) return e.value;
    }
    return null;
  }
}
