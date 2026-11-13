import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/db/database.dart';
import '../data/models/track.dart';
import 'download_service.dart';
import 'online/itunes.dart';
import 'online/ytmusic.dart' show YtMusicSearch, sameVersion;
import 'song_matcher.dart';

/// File names of downloaded songs (1.20.5): the song's official name from
/// iTunes when surely the same song, else its name in the app — never the
/// video title it came with. Only the file is renamed; the song keeps its
/// name, playlists, like and plays.
class FileNames {
  /// iTunes' title for [t] when surely the same song (same artist, close
  /// title, the same take, length within 5 s), else null.
  static String? officialTitle(Track t, List<ITunesSong> results) {
    final want = SongKey(t.title, t.artist, durationMs: t.durationMs);
    final candidates = [
      for (final r in results)
        if (sameVersion(t.title, r.title) && SongMatcher.sameArtistField(want, SongKey(r.title, r.artist))) r,
    ];
    final (song, result) = SongMatcher.best(want, candidates, (ITunesSong r) => SongKey(r.title, r.artist, durationMs: r.durationMs));
    if (song == null || result.level != MatchLevel.sure) return null;
    if (t.durationMs != null && song.durationMs != null && (t.durationMs! - song.durationMs!).abs() > 5000) return null;
    return song.title;
  }

  /// The name [t]'s file should have (without folder or extension).
  static Future<String> nameFor(Track t, ITunesSearch itunes) async {
    try {
      final store = YtMusicSearch.localeFor('${t.title} ${t.artist}') == 'ja' ? 'jp' : 'tw';
      final artist = t.artist == '未知演出者' ? '' : SongMatcher.searchArtist(t.artist);
      final results = await itunes.search([SongMatcher.searchTitle(t.title, t.artist), artist].where((s) => s.isNotEmpty).join(' '), limit: 25, store: store);
      final official = officialTitle(t, results);
      if (official != null && official.trim().isNotEmpty) return official.trim();
    } catch (_) {}
    return t.title;
  }

  /// Where [t]'s file goes when named [name]: beside it; 「name - artist」
  /// when another file has the name, then a number.
  static String targetFor(Track t, String name) {
    final dir = p.dirname(t.uri);
    final ext = p.extension(t.uri);
    String path(String base) => p.join(dir, DownloadService.fileNameFor(base, 'x$ext'));
    bool same(String a, String b) => p.equals(a, b);
    bool free(String candidate) => same(candidate, t.uri) || !File(candidate).existsSync();
    var target = path(name);
    // Exactly its name already (case included): unchanged.
    if (p.normalize(target) == p.normalize(t.uri)) return t.uri;
    if (free(target)) return target;
    final withArtist = '$name - ${t.artist}';
    target = path(withArtist);
    for (var i = 2; !free(target); i++) {
      target = path('$withArtist ($i)');
    }
    return target;
  }

  /// [t]'s file renamed to [name]; its library entry follows. Returns the
  /// song as it now is (unchanged when nothing needed renaming or it failed).
  static Future<Track> rename(AppDatabase db, Track t, String name) async {
    final file = File(t.uri);
    if (t.uri.isEmpty || !file.existsSync()) return t;
    final target = targetFor(t, name);
    if (target == t.uri) return t;
    try {
      if (Platform.isWindows && target.toLowerCase() == t.uri.toLowerCase()) {
        // Only the case changes: through a temporary name.
        final tmp = '$target.ouo-rename';
        await file.rename(tmp);
        await File(tmp).rename(target);
      } else {
        await file.rename(target);
      }
    } on FileSystemException {
      return t;
    }
    await db.moveTrackPaths({t.uri: target});
    return Track(
        id: target, uri: target, title: t.title, artist: t.artist, album: t.album, durationMs: t.durationMs, art: t.art, source: t.source,
        trackNo: t.trackNo, addedAt: t.addedAt);
  }
}
