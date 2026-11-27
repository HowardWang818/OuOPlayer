import 'dart:convert';
import 'dart:math';

import '../../data/db/database.dart';
import '../../data/models/track.dart';
import 'merge.dart';

/// {device: ms} as read from JSON.
Map<String, int> msByDevice(Object? j) => {
      if (j is Map)
        for (final e in j.entries)
          if (e.value is num) '${e.key}': (e.value as num).toInt(),
    };

/// Plays (v1.12.0): each device lists its own plays (song names, when, how
/// long, no file paths) in `v2-plays-<device>.json`; the others bring them
/// into their listening log, marked with where they came from, so play
/// counts, recently played, statistics and the year review cover both.
///
/// A play both devices heard (接續播放) lists each one's share in `p`
/// (1.23.0); only ever the larger of a share is kept, so the order it
/// arrives in doesn't matter and the times add up.
class PlaySync {
  PlaySync(this.db);
  final AppDatabase db;

  static const _music = [TrackSource.local, TrackSource.download];

  /// This device's ([me]) own plays of songs (not podcasts / previews).
  Future<List<Map<String, Object?>>> export([String? me]) async {
    final rows = await db.db.rawQuery('SELECT l.id, l.played_at, l.listened_ms, l.source, l.origin, l.parts, t.title, t.artist, t.album, t.duration_ms '
        'FROM listening_log l JOIN tracks t ON t.id = l.track_id WHERE l.origin IS NULL AND l.source IN (?, ?) ORDER BY l.id',
        _music);
    return [
      for (final r in rows)
        {
          'id': r['id'],
          't': r['title'],
          'a': r['artist'],
          'al': r['album'],
          'ms': r['duration_ms'],
          'at': r['played_at'],
          'l': r['listened_ms'],
          's': r['source'],
          if (me != null && r['parts'] != null) 'p': _sorted(AppDatabase.sharesOf(r, me)!),
        },
    ];
  }

  static Map<String, int> _sorted(Map<String, int> m) => {for (final k in m.keys.toList()..sort()) k: m[k]!};

  /// Brings [plays] of [device] in (each once; more heard updates it).
  /// [me]: this device. Returns how many were new.
  Future<int> import(String device, List plays, {String? me}) async {
    if (plays.isEmpty) return 0;
    final rows = await db.db.query('listening_log', columns: ['id', 'remote_id', 'listened_ms', 'played_at', 'origin', 'parts']);
    final known = <String, Map<String, Object?>>{};
    // A play is known by when it began, whoever sends it (v1.14.6): after a
    // reinstall or a restored backup the same plays come again under other
    // ids, from this device's old self or from another that restored them.
    final knownAt = <int, Map<String, Object?>>{};
    for (final r in rows) {
      knownAt.putIfAbsent(r['played_at'] as int, () => r);
      if (r['origin'] == device && r['remote_id'] != null) known['${r['remote_id']}'] = r;
    }
    final bySong = <String, List<Track>>{};
    for (final t in await db.tracks()) {
      bySong.putIfAbsent(songKey(t.title, t.artist), () => []).add(t);
    }
    for (final r in await db.db.query('track_edits')) {
      final t = await db.track('${r['track_id']}');
      if (t != null) bySong.putIfAbsent('${r['root']}', () => []).add(t);
    }
    var added = 0;
    final merged = <Object?>{};
    final batch = db.db.batch();
    // Songs passed on the way while deleting (a device before 1.20.9 still sends them).
    final passed = AppDatabase.skippedThrough([
      for (final p in plays.whereType<Map>())
        if (p['at'] is num) (p['id'], (p['at'] as num).toInt(), (p['l'] as num?)?.toInt() ?? 0),
    ]);
    for (final p in plays.whereType<Map>()) {
      if (passed.contains(p['id'])) continue;
      final rid = '$device:${p['id']}';
      final listened = (p['l'] as num?)?.toInt() ?? 0;
      final at = (p['at'] as num).toInt();
      final shares = p['p'] is Map ? msByDevice(p['p']) : null;
      // Known already, or the same play (1.20.9: carried on with 接續播放 on
      // the other device).
      final row = known[rid] ?? knownAt[at];
      if (row != null) {
        final id = row['id'];
        if (id == null || !merged.add(id)) continue; // twice in the same list
        final cur = row['listened_ms'] as int;
        if (row['parts'] == null) {
          // Can't be split: the longer time heard, the same on both.
          if (listened > cur) batch.rawUpdate('UPDATE listening_log SET listened_ms = ? WHERE id = ? AND listened_ms < ?', [listened, id, listened]);
          continue;
        }
        final parts = AppDatabase.partsFrom(row['parts']);
        final here = row['origin'] == null ? max(0, cur - AppDatabase.partsTotal(parts)) : 0;
        var more = 0;
        var changed = false;
        if (shares == null) {
          // From before 1.23.0, a total: what it has beyond this is theirs.
          if (listened > cur) {
            more = listened - cur;
            parts[device] = (parts[device] ?? 0) + more;
            changed = true;
          }
        } else {
          for (final e in shares.entries) {
            if (e.key == me && row['origin'] == null) {
              // This device's own share, restored from an older backup.
              if (e.value > here) more += e.value - here;
            } else if (e.value > (parts[e.key] ?? 0)) {
              more += e.value - (parts[e.key] ?? 0);
              parts[e.key] = e.value;
              changed = true;
            }
          }
        }
        // Added: the player may be adding to this very play.
        if (changed || more > 0) {
          batch.rawUpdate('UPDATE listening_log SET listened_ms = listened_ms + ?, parts = ? WHERE id = ?', [more, jsonEncode(parts), id]);
        }
        continue;
      }
      knownAt[at] = {'id': null};
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
        'listened_ms': shares == null ? listened : AppDatabase.partsTotal(shares),
        'source': p['s'] ?? TrackSource.local,
        'origin': device,
        'remote_id': rid,
        'parts': shares == null ? null : jsonEncode(shares),
      });
      added++;
    }
    await batch.commit(noResult: true);
    if (added > 0) db.notifyChanged();
    return added;
  }
}
