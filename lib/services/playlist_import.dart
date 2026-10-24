import 'package:path/path.dart' as p;

import '../data/models/track.dart';
import 'song_matcher.dart';

/// One entry of an M3U playlist.
class M3uEntry {
  const M3uEntry(this.location, {this.title, this.artist, this.durationSec});

  /// Path or URL as written in the file.
  final String location;
  final String? title;
  final String? artist;
  final int? durationSec;

  bool get isUrl => location.startsWith('http://') || location.startsWith('https://');

  /// For the 「找不到」 list.
  String get label => title != null ? (artist != null ? '$title - $artist' : title!) : p.basename(location);
}

class M3uPlaylist {
  const M3uPlaylist(this.name, this.entries);
  final String? name;
  final List<M3uEntry> entries;

  /// Reads M3U / M3U8 text: #EXTINF:seconds,Artist - Title lines, #PLAYLIST
  /// names, file:// URIs and paths relative to [baseDir].
  static M3uPlaylist parse(String text, {String? baseDir}) {
    String? name;
    String? title, artist;
    int? duration;
    final entries = <M3uEntry>[];
    for (final raw in text.replaceAll('\r', '').split('\n')) {
      final line = raw.replaceFirst('﻿', '').trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#PLAYLIST:')) {
        name = line.substring(10).trim();
      } else if (line.startsWith('#EXTINF:')) {
        final body = line.substring(8);
        final comma = body.indexOf(',');
        duration = int.tryParse((comma < 0 ? body : body.substring(0, comma)).trim().split(' ').first);
        if (duration != null && duration < 0) duration = null;
        final info = comma < 0 ? '' : body.substring(comma + 1).trim();
        final dash = info.indexOf(' - ');
        artist = dash < 0 ? null : info.substring(0, dash).trim();
        title = dash < 0 ? (info.isEmpty ? null : info) : info.substring(dash + 3).trim();
      } else if (!line.startsWith('#')) {
        var loc = line;
        if (loc.startsWith('file://')) loc = Uri.parse(loc).toFilePath(windows: RegExp(r'^file:///[A-Za-z]:').hasMatch(loc));
        final isUrl = loc.startsWith('http://') || loc.startsWith('https://');
        if (!isUrl && baseDir != null && p.isRelative(loc) && !RegExp(r'^[A-Za-z]:[\\/]').hasMatch(loc)) {
          // Android paths keep 「/」 even when this runs on Windows (tests).
          final ctx = baseDir.startsWith('/') ? p.posix : p.context;
          loc = ctx.normalize(ctx.join(baseDir, loc));
        }
        entries.add(M3uEntry(loc, title: title, artist: artist, durationSec: duration));
        title = artist = null;
        duration = null;
      }
    }
    return M3uPlaylist(name, entries);
  }
}

/// Finds the library song for an entry: same path, else same file name,
/// else the song SongMatcher is sure about (title and artist as #EXTINF
/// or the backup wrote them).
class LibraryMatcher {
  LibraryMatcher(Iterable<Track> library)
      : _songs = SongIndex(library.where((t) => t.source != TrackSource.missing), (Track t) => SongKey(t.title, t.artist, durationMs: t.durationMs)) {
    for (final t in library) {
      if (t.source == TrackSource.missing) continue;
      _byPath[_key(t.uri)] = t;
      _byName.putIfAbsent(p.basename(t.uri).toLowerCase(), () => t);
    }
  }

  final _byPath = <String, Track>{};
  final _byName = <String, Track>{};
  final SongIndex<Track> _songs;

  static String _key(String path) => p.normalize(path).replaceAll('\\', '/').toLowerCase();

  Track? find(String location, {String? title, String? artist, int? durationMs}) {
    final byFile = _byPath[_key(location)] ?? _byName[p.basename(location.replaceAll('\\', '/')).toLowerCase()];
    if (byFile != null || title == null) return byFile;
    final (t, r) = _songs.find(SongKey(title, artist ?? '', durationMs: durationMs));
    return r.level == MatchLevel.sure ? t : null;
  }
}
