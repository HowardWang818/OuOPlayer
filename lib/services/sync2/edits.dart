import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../../data/db/database.dart';
import '../../data/models/track.dart';
import '../sync/drive_client.dart';
import 'merge.dart';

/// Lyrics of a song on this device (null: none).
typedef LyricsOf = Future<({String lrc, bool manual, int at})?> Function(Track t);

/// Song details changed by the user (v1.12.0): 編輯資訊, batch edits, 找封面,
/// 找原文歌名, and the lyrics found or picked. Each device lists the latest
/// edit of every synced song in `v2-edits-<device>.json`; the latest (time,
/// then device) wins. A song is known everywhere by its root: its first
/// title|artist, which stays the same however often it is renamed. Covers go
/// through Drive as `v2-cover-<sha256>` until every other device has them.
class EditSync {
  EditSync({required this.db, required this.drive, this.lyricsOf, this.setLyrics, this.writeTags, this.storeArt});

  final AppDatabase db;
  final DriveStore drive;
  final LyricsOf? lyricsOf;
  final Future<void> Function(Track t, String lrc, bool manual)? setLyrics;

  /// Writes the new details into the file too (Windows: Android would ask
  /// for each file other apps made, in the middle of a sync).
  final Future<void> Function(Track t, Uint8List? cover)? writeTags;
  final Future<String> Function(Uint8List bytes, String mime)? storeArt;

  /// Lyrics the last [apply] took from another device (root → lrc).
  final adoptedLyrics = <String, String>{};

  /// A user edit on this device: its row becomes the song's latest edit.
  Future<void> recorded(Track before, Track after, String device, int now) async {
    final old = (await db.db.query('track_edits', where: 'track_id = ?', whereArgs: [after.id])).firstOrNull;
    String? cover = old?['cover'] as String?;
    if (after.art != before.art) {
      final f = after.art == null || after.art!.startsWith('http') ? null : File(after.art!);
      cover = f != null && f.existsSync() ? sha256.convert(await f.readAsBytes()).toString() : null;
    }
    await db.db.insert(
        'track_edits',
        {
          'track_id': after.id,
          'root': old?['root'] ?? songKey(before.title, before.artist),
          'root_ms': old?['root_ms'] ?? before.durationMs,
          'title': after.title,
          'artist': after.artist,
          'album': after.album,
          'cover': cover,
          'at': now,
          'device': device,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// root → the song here it stands for (edited songs by their row,
  /// unedited ones by their names).
  Future<Map<String, Track>> roots(List<Track> library) async {
    final byId = {for (final t in library) t.id: t};
    final out = <String, Track>{};
    for (final t in library) {
      out.putIfAbsent(songKey(t.title, t.artist), () => t);
    }
    for (final r in await db.db.query('track_edits')) {
      final t = byId[r['track_id']];
      if (t != null) out['${r['root']}'] = t;
    }
    return out;
  }

  /// What this device tells the others: the latest edit of each [synced]
  /// song (song keys of the synced playlists), and its lyrics.
  Future<Map<String, Object?>> export(Set<String> synced, List<Track> library, Map<String, File> coversOut) async {
    final byId = {for (final t in library) t.id: t};
    final edits = <String, Object?>{};
    for (final r in await db.db.query('track_edits')) {
      final t = byId[r['track_id']];
      if (t == null) continue;
      final root = '${r['root']}';
      if (!synced.contains(root) && !synced.contains(songKey(t.title, t.artist))) continue;
      edits[root] = {'ms': r['root_ms'], 't': r['title'], 'a': r['artist'], 'al': r['album'], 'c': r['cover'], 'at': r['at'], 'd': r['device']};
      final c = r['cover'] as String?;
      if (c != null && t.art != null && File(t.art!).existsSync()) coversOut[c] = File(t.art!);
    }
    final lyrics = <String, Object?>{};
    if (lyricsOf != null) {
      final rootOf = {for (final r in await db.db.query('track_edits')) '${r['track_id']}': '${r['root']}'};
      for (final t in library) {
        final root = rootOf[t.id] ?? songKey(t.title, t.artist);
        if (!synced.contains(root) && !synced.contains(songKey(t.title, t.artist))) continue;
        final l = await lyricsOf!(t);
        if (l != null) lyrics[root] = {'l': l.lrc, 'm': l.manual, 'at': l.at};
      }
    }
    return {'edits': edits, 'lyrics': lyrics};
  }

  /// Applies the other devices' edits and lyrics here. Returns how many songs changed.
  Future<int> apply(List<Map> theirs, String me, Map<String, String> files) async {
    adoptedLyrics.clear();
    var changed = 0;
    final library = await db.tracks();
    final roots = await this.roots(library);
    final mine = {for (final r in await db.db.query('track_edits')) '${r['root']}': r};
    // Latest edit of each root over all the other devices.
    final latest = <String, Map>{};
    for (final dev in theirs) {
      for (final e in ((dev['edits'] as Map?) ?? const {}).entries) {
        final m = e.value as Map;
        final cur = latest['${e.key}'];
        if (cur == null || _newer(m, cur)) latest['${e.key}'] = m;
      }
    }
    for (final MapEntry(key: root, value: m) in latest.entries) {
      final t = roots[root];
      if (t == null || t.isRemote) continue;
      final ms = m['ms'] as int?;
      if (mine[root] == null && ms != null && t.durationMs != null && (t.durationMs! - ms).abs() > 3000) continue;
      final here = mine[root];
      if (here != null && !_newer(m, {'at': here['at'], 'd': here['device']})) continue;
      var art = t.art;
      Uint8List? cover;
      final c = m['c'] as String?;
      if (c != null && c != here?['cover'] && files['v2-cover-$c'] != null && storeArt != null) {
        try {
          cover = await drive.download(files['v2-cover-$c']!);
          art = await storeArt!(cover, 'image/jpeg');
        } catch (_) {}
      }
      final updated = Track(
        id: t.id,
        uri: t.uri,
        title: '${m['t'] ?? t.title}',
        artist: '${m['a'] ?? t.artist}',
        album: '${m['al'] ?? t.album}',
        durationMs: t.durationMs,
        art: art,
        source: t.source,
        trackNo: t.trackNo,
        addedAt: t.addedAt,
      );
      if (writeTags != null) {
        try {
          await writeTags!(updated, cover);
        } catch (_) {}
      }
      await db.db.update('tracks', {'title': updated.title, 'artist': updated.artist, 'album': updated.album, 'art': updated.art},
          where: 'id = ?', whereArgs: [t.id]);
      await db.db.insert(
          'track_edits',
          {
            'track_id': t.id,
            'root': root,
            'root_ms': ms ?? t.durationMs,
            'title': updated.title,
            'artist': updated.artist,
            'album': updated.album,
            'cover': c ?? here?['cover'],
            'at': m['at'],
            'device': m['d'],
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      changed++;
    }
    // Lyrics: picked by hand beats found; otherwise the latest; never the same twice.
    if (lyricsOf != null && setLyrics != null) {
      final best = <String, Map>{};
      for (final dev in theirs) {
        for (final e in ((dev['lyrics'] as Map?) ?? const {}).entries) {
          final m = e.value as Map;
          final cur = best['${e.key}'];
          if (cur == null || _betterLyrics(m, cur)) best['${e.key}'] = m;
        }
      }
      final now = await this.roots(await db.tracks());
      for (final MapEntry(key: root, value: m) in best.entries) {
        final t = now[root];
        if (t == null || t.isRemote) continue;
        final here = await lyricsOf!(t);
        if (here != null && (here.lrc == m['l'] || !_betterLyrics(m, {'l': here.lrc, 'm': here.manual, 'at': here.at}))) continue;
        await setLyrics!(t, '${m['l']}', m['m'] == true);
        adoptedLyrics[root] = '${m['l']}';
        changed++;
      }
    }
    return changed;
  }

  static bool _newer(Map a, Map b) {
    final at = (a['at'] as num?)?.toInt() ?? 0, bt = (b['at'] as num?)?.toInt() ?? 0;
    return at > bt || (at == bt && '${a['d']}'.compareTo('${b['d']}') > 0);
  }

  static bool _betterLyrics(Map a, Map b) {
    final am = a['m'] == true, bm = b['m'] == true;
    if (am != bm) return am;
    return ((a['at'] as num?)?.toInt() ?? 0) > ((b['at'] as num?)?.toInt() ?? 0);
  }

  /// Covers this device's edits need on Drive: uploaded once; removed once
  /// every other device ([seen]: the covers each one has applied) has it.
  Future<void> relayCovers(Map<String, File> covers, List<Set<String>> seen, List<DriveFile> files) async {
    final names = {for (final f in files) f.name: f.id};
    for (final MapEntry(key: sha, value: f) in covers.entries) {
      final name = 'v2-cover-$sha';
      final everyone = seen.isNotEmpty && seen.every((s) => s.contains(sha));
      if (everyone) {
        if (names[name] != null) await drive.delete(names[name]!);
      } else if (names[name] == null && f.existsSync()) {
        await drive.upload(name, await f.readAsBytes(), mime: 'image/jpeg');
      }
    }
  }

  /// Covers applied here (sent to the others, so they can drop theirs from Drive).
  Future<List<String>> coversHere() async =>
      [for (final r in await db.db.query('track_edits', columns: ['cover'], where: 'cover IS NOT NULL')) '${r['cover']}'];
}
