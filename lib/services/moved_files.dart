import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/db/database.dart';
import '../data/models/track.dart';
import 'song_matcher.dart' show foldText;

/// Music moved to another folder by hand (1.20.15): scanning the new folder
/// added every song again as a new one, while the old entries (in the
/// playlists, liked, with their play counts) pointed at files that were
/// gone, so the other device sent all of them again. A new file with the
/// same file name as a song whose file is gone, and the same song, is that
/// song moved.
class MovedFiles {
  static const _repaired = 'moved_files_v1';

  static bool _gone(Track t) =>
      (t.source == TrackSource.local || t.source == TrackSource.download) && !t.isRemote && t.uri.isNotEmpty && !File(t.uri).existsSync();

  static bool _here(Track t) => !t.isRemote && t.uri.isNotEmpty && File(t.uri).existsSync();

  static bool _same(Track old, Track now) {
    if (old.durationMs != null && now.durationMs != null) return (old.durationMs! - now.durationMs!).abs() <= 2000;
    // Without lengths: the same title (the file name is already the same).
    return foldText(old.title) == foldText(now.title);
  }

  /// Old id → new id, for the songs in [found] that are a [library] song
  /// moved. A name that fits more than one song is left alone.
  static Map<String, String> pairs(Iterable<Track> library, Iterable<Track> found) {
    final byName = <String, List<Track>>{};
    for (final t in library.where(_gone)) {
      byName.putIfAbsent(p.basename(t.uri).toLowerCase(), () => []).add(t);
    }
    if (byName.isEmpty) return const {};
    final out = <String, String>{};
    final taken = <String>{};
    final news = [for (final n in found) if (_here(n)) n];
    final perName = <String, int>{};
    for (final n in news) {
      final k = p.basename(n.uri).toLowerCase();
      perName[k] = (perName[k] ?? 0) + 1;
    }
    for (final n in news) {
      final name = p.basename(n.uri).toLowerCase();
      if (perName[name] != 1) continue;
      final olds = [for (final o in byName[name] ?? const <Track>[]) if (o.id != n.id && _same(o, n)) o];
      if (olds.length != 1 || !taken.add(olds.first.id)) continue;
      out[olds.first.id] = n.id;
    }
    return out;
  }

  /// [found] (just added) that are moved songs go back to the songs they were.
  static Future<int> merge(AppDatabase db, Iterable<Track> found) async {
    final moved = pairs(await db.tracks(), found);
    await db.mergeMovedTracks(moved);
    return moved.length;
  }

  /// Once: songs moved before 1.20.15 and already added again.
  static Future<int> repairOnce(AppDatabase db) async {
    if ((await db.allSettings())[_repaired] == '1') return 0;
    final library = await db.tracks();
    final moved = pairs(library, library);
    await db.mergeMovedTracks(moved);
    await db.setSetting(_repaired, '1');
    return moved.length;
  }
}
