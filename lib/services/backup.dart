import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../data/db/database.dart';
import '../data/models/track.dart';
import 'library_scanner.dart';
import 'missing_songs.dart';
import 'playlist_import.dart';
import 'song_matcher.dart';

/// Whether a setting stays out of backups. `sync2_*` is this device's own
/// sync state: from a backup it would make a new install look already synced.
bool _private(String key) => _privateSettings.contains(key) || key.startsWith('sync2_');

/// Settings that never go into a backup: secrets and per-device state.
const _privateSettings = {
  'youtube_api_key', 'last_session', 'last_music_session', 'auto_backup_dir', 'auto_backup_last', 'update_last_check',
  // Google Drive sync: the sign-in and this device's own sync state.
  'gdrive_refresh', 'sync_signed_in', 'sync_device_id', 'sync_last', 'sync_email', 'sync_base', 'sync_remote_base', 'sync_stamps',
  'sync_requests', 'sync_history_seen', 'sync_history_sent', 'sync_library_sent', 'sync_resume_seen', 'sync_declined', 'sync_skip', 'start_with_windows', 'sync_pushes', 'sync_cloud_library', 'gdrive_file_scope',
};

/// Covers replaced by hand are kept up to this much in a backup: all the
/// library's covers wouldn't fit in one file, and most are in the songs' tags.
const _coverLimit = 64 << 20;

/// Where the plays of a backup from before v1.14.6 came from: unknown, so
/// sync never sends them as this device's own.
const restoredOrigin = 'restored';

Future<Directory?> _lyricsDir() async {
  try {
    return Directory(p.join((await getApplicationSupportDirectory()).path, 'lyrics'));
  } catch (_) {
    return null;
  }
}

/// Builds a backup of everything the user made: playlists (with custom
/// covers), folders, likes, play counts, podcast subscriptions and progress,
/// download history and settings, and the library's song details, lyrics and
/// replaced covers. Songs are listed with path, title, artist and length so
/// they can be found again on another device.
Future<Map<String, Object?>> buildBackup(AppDatabase app, {Directory? lyricsDir}) async {
  final db = app.db;
  final tracks = {for (final r in await db.query('tracks')) r['id'] as String: r};
  Map<String, Object?> ref(String id) {
    final t = tracks[id];
    return {
      'uri': t?['uri'] ?? id,
      'title': t?['title'],
      'artist': t?['artist'],
      'album': t?['album'],
      'duration_ms': t?['duration_ms'],
      'source': t?['source'],
    };
  }

  final folders = await db.query('playlist_folders', orderBy: 'id');
  final playlists = <Map<String, Object?>>[];
  for (final pl in await db.query('playlists', orderBy: 'id')) {
    final rows = await db.query('playlist_tracks', where: 'playlist_id = ?', whereArgs: [pl['id']], orderBy: 'position');
    String? cover;
    final c = pl['cover'] as String?;
    if (c != null && File(c).existsSync()) cover = base64Encode(await File(c).readAsBytes());
    playlists.add({
      'name': pl['name'],
      'created_at': pl['created_at'],
      'folder': folders.where((f) => f['id'] == pl['folder_id']).map((f) => f['name']).firstOrNull,
      'cover': cover,
      'cover_ext': c == null ? null : p.extension(c),
      'tracks': [for (final r in rows) ref(r['track_id'] as String)],
      // Its place in sync: without it a restored list is another list.
      'uid': pl['uid'],
      'synced': pl['synced'],
      'items': [for (final r in rows) r['item_id']],
    });
  }
  final settings = await app.allSettings();
  final edits = await db.query('track_edits');
  var coverBytes = 0;
  final covers = <String, String>{};
  for (final e in edits) {
    final art = tracks[e['track_id']]?['art'] as String?;
    if (e['cover'] == null || art == null || art.startsWith('http') || !File(art).existsSync()) continue;
    final size = File(art).lengthSync();
    if (coverBytes + size > _coverLimit) continue;
    coverBytes += size;
    covers[tracks[e['track_id']]!['uri'] as String] = base64Encode(await File(art).readAsBytes());
  }
  final lyrics = lyricsDir ?? await _lyricsDir();
  return {
    'app': 'OuOPlayer',
    'backup_version': 2,
    'exported_at': DateTime.now().toIso8601String(),
    'settings': {for (final e in settings.entries) if (!_private(e.key)) e.key: e.value},
    'library': [
      for (final t in tracks.values)
        if (t['source'] == TrackSource.local || t['source'] == TrackSource.download)
          {'uri': t['uri'], 'title': t['title'], 'artist': t['artist'], 'album': t['album']},
    ],
    'track_edits': [
      for (final e in edits)
        if (tracks[e['track_id']] != null) {...e, 'uri': tracks[e['track_id']]!['uri']},
    ],
    'covers': covers,
    'lyrics': {
      if (lyrics != null && lyrics.existsSync())
        for (final f in lyrics.listSync().whereType<File>())
          if (f.path.endsWith('.json')) p.basename(f.path): await f.readAsString(),
    },
    'folders': [for (final f in folders) {'name': f['name'], 'created_at': f['created_at']}],
    'playlists': playlists,
    'favorites': [for (final r in await db.query('favorites')) {...ref(r['track_id'] as String), 'added_at': r['added_at']}],
    'plays': [
      for (final r in await db.query('plays')) {...ref(r['track_id'] as String), 'count': r['count'], 'last_played': r['last_played']},
    ],
    // Older backups (before v0.12.0) have no listening log; that's fine.
    'listening': [
      for (final r in await db.query('listening_log', orderBy: 'played_at'))
        {
          ...ref(r['track_id'] as String),
          'played_at': r['played_at'],
          'listened_ms': r['listened_ms'],
          'log_source': r['source'],
          'estimated': r['estimated'],
          // Which device played it (v1.14.6): restored, another device's play
          // stays theirs and isn't sent out again as this one's.
          'origin': r['origin'],
          'remote_id': r['remote_id'],
        },
    ],
    'podcasts': await db.query('podcasts'),
    'podcast_progress': await db.query('podcast_progress'),
    'download_history': await db.query('download_history'),
  };
}

/// What a restore did.
class RestoreReport {
  RestoreReport({required this.playlists, required this.songs, required this.missing, this.renamed = 0});

  /// Songs whose name or cover came back from the backup.
  final int renamed;
  final int playlists;
  final int songs;
  final List<String> missing;
}

/// The parts of a backup that can be restored on their own.
enum RestorePart {
  settings('設定'),
  songs('歌名、封面和歌詞'),
  playlists('播放清單和資料夾'),
  likes('已按讚的歌曲'),
  history('播放次數和收聽紀錄'),
  podcasts('Podcast 訂閱和收聽進度');

  const RestorePart(this.label);
  final String label;
}

/// Replaces the chosen [parts] (all by default) with [backup]; the others
/// are left exactly as they are. Songs are matched to this library by path,
/// file name, or title and artist; files that exist but weren't scanned yet
/// are added. Music folders from another device are kept only if they exist here.
Future<RestoreReport> restoreBackup(AppDatabase app, LibraryScanner scanner, Map<String, Object?> backup,
    {Directory? coverDir, Directory? lyricsDir, Set<RestorePart> parts = const {...RestorePart.values}}) async {
  if (backup['app'] != 'OuOPlayer') throw '這不是 OuOPlayer 的備份檔';
  final db = app.db;
  final matcher = LibraryMatcher(await app.tracks());
  final resolved = <String, String?>{};
  final missing = <String>{};
  var songs = 0;

  Future<String?> resolve(Object? raw) async {
    if (raw is! Map) return null;
    final uri = raw['uri'] as String? ?? '';
    final key = '$uri|${raw['title']}|${raw['artist']}';
    if (resolved.containsKey(key)) return resolved[key];
    String? id;
    final source = raw['source'] as String?;
    if (source == TrackSource.missing) {
      final t = await MissingSongs.create(app, raw['title'] as String? ?? '', raw['artist'] as String? ?? '',
          album: raw['album'] as String? ?? '', durationMs: raw['duration_ms'] as int?);
      resolved[key] = t.id;
      return t.id;
    }
    if (uri.startsWith('http://') || uri.startsWith('https://')) {
      // Online songs are stored as they were.
      await db.insert(
          'tracks',
          {
            'id': uri,
            'uri': uri,
            'title': raw['title'] ?? uri,
            'artist': raw['artist'],
            'album': raw['album'],
            'duration_ms': raw['duration_ms'],
            'source': source ?? TrackSource.url,
            'added_at': DateTime.now().millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
      id = uri;
    } else {
      id = matcher.find(uri, title: raw['title'] as String?, artist: raw['artist'] as String?)?.id;
      if (id == null && uri.isNotEmpty && File(uri).existsSync()) {
        id = (await scanner.importFile(uri, source: source == TrackSource.download ? TrackSource.download : TrackSource.local))?.id;
      }
      if (id == null) missing.add([raw['title'], raw['artist']].whereType<String>().join(' - ').ifEmpty(p.basename(uri)));
    }
    resolved[key] = id;
    return id;
  }

  final covers = coverDir ?? Directory(p.join((await getApplicationSupportDirectory()).path, 'covers'));
  await covers.create(recursive: true);
  final playlists = parts.contains(RestorePart.playlists) ? (backup['playlists'] as List? ?? const []).cast<Map>() : const <Map>[];
  // Resolve every song first, so the replacement below is quick and atomic.
  final playlistIds = <List<String>>[];
  final playlistItems = <List<Object?>>[];
  for (final pl in playlists) {
    final ids = <String>[];
    final items = <Object?>[];
    final tracks = pl['tracks'] as List? ?? const [];
    final kept = pl['items'] as List? ?? const [];
    for (var j = 0; j < tracks.length; j++) {
      final id = await resolve(tracks[j]);
      if (id == null) continue;
      ids.add(id);
      items.add(j < kept.length ? kept[j] : null);
    }
    playlistIds.add(ids);
    playlistItems.add(items);
  }
  // Older backups don't say which lists sync: a list synced here stays synced.
  final syncedHere = {
    if (parts.contains(RestorePart.playlists))
      for (final r in await db.query('playlists', where: 'synced = 1 AND uid IS NOT NULL')) '${r['name']}': r['uid'] as String,
  };
  final favorites = <(String, Object?)>[];
  for (final f in parts.contains(RestorePart.likes) ? (backup['favorites'] as List? ?? const []) : const []) {
    final id = await resolve(f);
    if (id != null) favorites.add((id, (f as Map)['added_at']));
  }
  final listening = <Map<String, Object?>>[];
  final history = parts.contains(RestorePart.history);
  for (final r in history ? (backup['listening'] as List? ?? const []).cast<Map>() : const <Map>[]) {
    // Podcast episodes aren't library songs: keep their ids as they were.
    final id = r['log_source'] == TrackSource.podcast ? r['uri'] as String? : await resolve(r);
    if (id == null) continue;
    listening.add({
      'track_id': id,
      'played_at': r['played_at'],
      'listened_ms': r['listened_ms'] ?? 0,
      'source': r['log_source'],
      'estimated': r['estimated'] ?? 0,
      // Older backups don't say where a play came from: none of them is sent
      // out as this device's (the device that played it already did).
      'origin': r.containsKey('origin') ? r['origin'] : restoredOrigin,
      'remote_id': r['remote_id'],
    });
  }
  final plays = <(String, Object?, Object?)>[];
  for (final r in history ? (backup['plays'] as List? ?? const []) : const []) {
    final id = await resolve(r);
    if (id != null) plays.add((id, (r as Map)['count'], r['last_played']));
  }

  await db.transaction((txn) async {
    for (final (part, tables) in [
      (RestorePart.playlists, ['playlist_tracks', 'playlists', 'playlist_folders']),
      (RestorePart.likes, ['favorites']),
      (RestorePart.history, ['plays']),
      (RestorePart.podcasts, ['podcasts', 'podcast_progress']),
    ]) {
      if (!parts.contains(part)) continue;
      for (final table in tables) {
        await txn.delete(table);
      }
    }
    // Only replace the log when the backup has one (older backups don't).
    if (history && backup.containsKey('listening')) {
      await txn.delete('listening_log');
      for (final r in listening) {
        await txn.insert('listening_log', r);
      }
    }
    final folderIds = <String, int>{};
    for (final f in (backup['folders'] as List? ?? const []).cast<Map>()) {
      folderIds[f['name'] as String] = await txn.insert('playlist_folders', {'name': f['name'], 'created_at': f['created_at']});
    }
    for (var i = 0; i < playlists.length; i++) {
      final pl = playlists[i];
      String? cover;
      if (pl['cover'] is String) {
        final f = File(p.join(covers.path, 'restored_${DateTime.now().microsecondsSinceEpoch}_$i${pl['cover_ext'] ?? '.jpg'}'));
        await f.writeAsBytes(base64Decode(pl['cover'] as String));
        cover = f.path;
      }
      final uid = pl['uid'] as String?;
      final here = syncedHere.remove(pl['name']);
      final id = await txn.insert('playlists', {
        'name': pl['name'],
        'created_at': pl['created_at'],
        'cover': cover,
        'folder_id': folderIds[pl['folder']],
        'uid': uid ?? here,
        'synced': uid != null ? pl['synced'] ?? 0 : (here != null ? 1 : 0),
      });
      final ids = playlistIds[i];
      for (var j = 0; j < ids.length; j++) {
        await txn.insert('playlist_tracks', {'playlist_id': id, 'track_id': ids[j], 'item_id': playlistItems[i][j], 'position': j});
      }
      songs += ids.length;
    }
    for (final (id, at) in favorites) {
      await txn.insert('favorites', {'track_id': id, 'added_at': at}, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    for (final (id, count, last) in plays) {
      await txn.insert('plays', {'track_id': id, 'count': count, 'last_played': last}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    // A backup made before v1.14.6 may hold the same plays several times.
    if (history && backup.containsKey('listening')) await AppDatabase.dropRepeatedPlays(txn);
    for (final table in parts.contains(RestorePart.podcasts) ? ['podcasts', 'podcast_progress'] : const <String>[]) {
      for (final r in (backup[table] as List? ?? const []).cast<Map>()) {
        await txn.insert(table, r.cast<String, Object?>(), conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
    for (final r in (backup['download_history'] as List? ?? const []).cast<Map>()) {
      await txn.insert('download_history', r.cast<String, Object?>(), conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    final settings = parts.contains(RestorePart.settings) ? (backup['settings'] as Map? ?? const {}).cast<String, Object?>() : const <String, Object?>{};
    for (final e in settings.entries) {
      if (_private(e.key) || e.value is! String) continue;
      final v = e.value as String;
      if (e.key == 'download_dir' && !Directory(v).existsSync()) continue;
      if (e.key == 'music_dirs') {
        final dirs = (jsonDecode(v) as List).cast<String>().where((d) => Directory(d).existsSync()).toList();
        if (dirs.isEmpty) continue;
        await txn.insert('settings', {'key': e.key, 'value': jsonEncode(dirs)}, conflictAlgorithm: ConflictAlgorithm.replace);
        continue;
      }
      await txn.insert('settings', {'key': e.key, 'value': v}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  });
  final renamed = parts.contains(RestorePart.songs) ? await _restoreSongs(app, scanner, backup, lyricsDir) : 0;
  app.notifyChanged();
  return RestoreReport(playlists: playlists.length, songs: songs, missing: missing.toList(), renamed: renamed);
}

/// Every song a backup names, by path. The newest backups list the whole
/// library; older ones only the songs in their lists, likes and plays.
Map<String, Map> _namesIn(Map<String, Object?> backup) {
  final names = <String, Map>{};
  void add(Object? songs) {
    for (final s in (songs as List? ?? const []).whereType<Map>()) {
      if (s['uri'] is String && s['title'] is String) names[s['uri'] as String] = s;
    }
  }

  add(backup['listening']);
  add(backup['plays']);
  add(backup['favorites']);
  for (final pl in (backup['playlists'] as List? ?? const []).whereType<Map>()) {
    add(pl['tracks']);
  }
  add(backup['library']);
  return names;
}

/// Puts back what only lived in the app: song names, replaced covers and
/// lyrics. Returns how many songs changed.
Future<int> _restoreSongs(AppDatabase app, LibraryScanner scanner, Map<String, Object?> backup, Directory? lyricsDir) async {
  final names = _namesIn(backup);
  final covers = (backup['covers'] as Map? ?? const {}).cast<String, Object?>();
  // 找原文歌名 before v1.12.0 is only in this list, keyed by the old names.
  Map renames = const {};
  try {
    renames = jsonDecode('${(backup['settings'] as Map?)?['sync_names'] ?? '{}'}') as Map;
  } catch (_) {}
  final edits = {for (final e in (backup['track_edits'] as List? ?? const []).whereType<Map>()) '${e['uri']}': e};
  var changed = 0;
  for (final t in await app.tracks()) {
    if (t.isRemote) continue;
    var name = names[t.uri];
    final old = renames['${foldText(t.title)}|${foldText(t.artist)}'];
    if ((name == null || name['title'] == t.title) && old is Map) {
      final ms = (old['from'] as Map?)?['ms'] as int?;
      if (ms == null || t.durationMs == null || (ms - t.durationMs!).abs() <= 3000) name = old;
    }
    final title = name?['title'] as String? ?? t.title;
    final artist = name?['artist'] as String? ?? t.artist;
    final album = name?['album'] as String? ?? t.album;
    final cover = covers[t.uri];
    final art = cover is String ? await scanner.storeArt(base64Decode(cover), 'image/jpeg') : t.art;
    if (title != t.title || artist != t.artist || album != t.album || art != t.art) {
      await app.db.update('tracks', {'title': title, 'artist': artist, 'album': album, 'art': art}, where: 'id = ?', whereArgs: [t.id]);
      await app.syncHooks?.trackEdited(
          t,
          Track(id: t.id, uri: t.uri, title: title, artist: artist, album: album, durationMs: t.durationMs, art: art, source: t.source, trackNo: t.trackNo, addedAt: t.addedAt));
      changed++;
    }
    final e = edits[t.uri];
    if (e != null) {
      await app.db.insert(
          'track_edits',
          {
            'track_id': t.id,
            'root': e['root'],
            'root_ms': e['root_ms'],
            'title': e['title'],
            'artist': e['artist'],
            'album': e['album'],
            'cover': e['cover'],
            'at': e['at'],
            'device': e['device'],
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }
  final lyrics = lyricsDir ?? await _lyricsDir();
  if (lyrics != null) {
    await lyrics.create(recursive: true);
    for (final e in (backup['lyrics'] as Map? ?? const {}).cast<String, Object?>().entries) {
      final f = File(p.join(lyrics.path, p.basename(e.key)));
      if (e.value is String && !f.existsSync()) await f.writeAsString(e.value as String);
    }
  }
  return changed;
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
