import '../../data/db/database.dart';
import '../../data/models/track.dart';
import 'merge.dart';

/// Plays (v1.12.0): each device lists its own plays (song names, when, how
/// long, no file paths) in `v2-plays-<device>.json`; the others bring them
/// into their listening log, marked with where they came from, so play
/// counts, recently played, statistics and the year review cover both.
class PlaySync {
  PlaySync(this.db);
  final AppDatabase db;

  static const _music = [TrackSource.local, TrackSource.download];

  /// This device's own plays of songs (not podcasts / previews).
  Future<List<Map<String, Object?>>> export() async {
    final rows = await db.db.rawQuery('SELECT l.id, l.played_at, l.listened_ms, l.source, t.title, t.artist, t.album, t.duration_ms '
        'FROM listening_log l JOIN tracks t ON t.id = l.track_id WHERE l.origin IS NULL AND l.source IN (?, ?) ORDER BY l.id',
        _music);
    return [
      for (final r in rows)
        {'id': r['id'], 't': r['title'], 'a': r['artist'], 'al': r['album'], 'ms': r['duration_ms'], 'at': r['played_at'], 'l': r['listened_ms'], 's': r['source']},
    ];
  }

  /// Brings [plays] of [device] in (each once; a longer listen updates it).
  /// Returns how many were new.
  Future<int> import(String device, List plays) async {
    if (plays.isEmpty) return 0;
    final rows = await db.db.query('listening_log', columns: ['remote_id', 'listened_ms', 'played_at'], where: 'origin = ?', whereArgs: [device]);
    final known = {for (final r in rows) if (r['remote_id'] != null) '${r['remote_id']}': r['listened_ms'] as int};
    // Brought in by the older sync (v1.7.0–v1.10, no id): known by when.
    final knownAt = {for (final r in rows) if (r['remote_id'] == null) r['played_at'] as int};
    final bySong = <String, List<Track>>{};
    for (final t in await db.tracks()) {
      bySong.putIfAbsent(songKey(t.title, t.artist), () => []).add(t);
    }
    for (final r in await db.db.query('track_edits')) {
      final t = await db.track('${r['track_id']}');
      if (t != null) bySong.putIfAbsent('${r['root']}', () => []).add(t);
    }
    var added = 0;
    final batch = db.db.batch();
    for (final p in plays.whereType<Map>()) {
      final rid = '$device:${p['id']}';
      final listened = (p['l'] as num?)?.toInt() ?? 0;
      if (known.containsKey(rid)) {
        if (listened > known[rid]!) batch.update('listening_log', {'listened_ms': listened}, where: 'remote_id = ?', whereArgs: [rid]);
        continue;
      }
      final at = (p['at'] as num).toInt();
      if (knownAt.contains(at)) continue;
      final key = songKey('${p['t']}', '${p['a']}');
      final ms = (p['ms'] as num?)?.toInt();
      final here = bySong[key]?.where((t) => ms == null || t.durationMs == null || (t.durationMs! - ms).abs() <= 3000).firstOrNull;
      String trackId;
      if (here != null) {
        trackId = here.id;
        batch.insert('history', {'track_id': here.id, 'played_at': at});
        batch.rawInsert('INSERT OR IGNORE INTO plays(track_id, count, last_played) VALUES(?, 0, ?)', [here.id, at]);
        batch.rawUpdate('UPDATE plays SET count = count + 1, last_played = MAX(COALESCE(last_played, 0), ?) WHERE track_id = ?', [at, here.id]);
      } else {
        // Only played there: its names, for the statistics.
        trackId = 'remote:$key';
        batch.rawInsert('INSERT OR IGNORE INTO remote_songs(id, title, artist, album, duration_ms) VALUES(?, ?, ?, ?, ?)',
            [trackId, '${p['t']}', '${p['a']}', '${p['al'] ?? ''}', ms]);
      }
      batch.insert('listening_log', {
        'track_id': trackId,
        'played_at': at,
        'listened_ms': listened,
        'source': p['s'] ?? TrackSource.local,
        'origin': device,
        'remote_id': rid,
      });
      added++;
    }
    await batch.commit(noResult: true);
    if (added > 0) db.notifyChanged();
    return added;
  }
}
