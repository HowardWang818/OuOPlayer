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

/// Settings that never go into a backup: secrets and per-device state.
const _privateSettings = {'youtube_api_key', 'last_session'};

/// Builds a backup of everything the user made: playlists (with custom
/// covers), folders, likes, play counts, podcast subscriptions and progress,
/// download history and settings. Songs are listed with path, title, artist
/// and length so they can be found again on another device.
Future<Map<String, Object?>> buildBackup(AppDatabase app) async {
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
    });
  }
  final settings = await app.allSettings();
  return {
    'app': 'OuOPlayer',
    'backup_version': 1,
    'exported_at': DateTime.now().toIso8601String(),
    'settings': {for (final e in settings.entries) if (!_privateSettings.contains(e.key)) e.key: e.value},
    'folders': [for (final f in folders) {'name': f['name'], 'created_at': f['created_at']}],
    'playlists': playlists,
    'favorites': [for (final r in await db.query('favorites')) {...ref(r['track_id'] as String), 'added_at': r['added_at']}],
    'plays': [
      for (final r in await db.query('plays')) {...ref(r['track_id'] as String), 'count': r['count'], 'last_played': r['last_played']},
    ],
    // Older backups (before v0.12.0) have no listening log; that's fine.
    'listening': [
      for (final r in await db.query('listening_log', orderBy: 'played_at'))
        {...ref(r['track_id'] as String), 'played_at': r['played_at'], 'listened_ms': r['listened_ms'], 'log_source': r['source'], 'estimated': r['estimated']},
    ],
    'podcasts': await db.query('podcasts'),
    'podcast_progress': await db.query('podcast_progress'),
    'download_history': await db.query('download_history'),
  };
}

/// What a restore did.
class RestoreReport {
  RestoreReport({required this.playlists, required this.songs, required this.missing});
  final int playlists;
  final int songs;
  final List<String> missing;
}

/// Replaces playlists, folders, likes, play counts, podcasts and settings
/// with [backup]. Songs are matched to this library by path, file name, or
/// title and artist; files that exist but weren't scanned yet are added.
/// Music folders from another device are kept only if they exist here.
Future<RestoreReport> restoreBackup(AppDatabase app, LibraryScanner scanner, Map<String, Object?> backup, {Directory? coverDir}) async {
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
  final playlists = (backup['playlists'] as List? ?? const []).cast<Map>();
  // Resolve every song first, so the replacement below is quick and atomic.
  final playlistIds = <List<String>>[];
  for (final pl in playlists) {
    final ids = <String>[];
    for (final t in (pl['tracks'] as List? ?? const [])) {
      final id = await resolve(t);
      if (id != null) ids.add(id);
    }
    playlistIds.add(ids);
  }
  final favorites = <(String, Object?)>[];
  for (final f in (backup['favorites'] as List? ?? const [])) {
    final id = await resolve(f);
    if (id != null) favorites.add((id, (f as Map)['added_at']));
  }
  final listening = <Map<String, Object?>>[];
  for (final r in (backup['listening'] as List? ?? const []).cast<Map>()) {
    // Podcast episodes aren't library songs: keep their ids as they were.
    final id = r['log_source'] == TrackSource.podcast ? r['uri'] as String? : await resolve(r);
    if (id == null) continue;
    listening.add({
      'track_id': id,
      'played_at': r['played_at'],
      'listened_ms': r['listened_ms'] ?? 0,
      'source': r['log_source'],
      'estimated': r['estimated'] ?? 0,
    });
  }
  final plays = <(String, Object?, Object?)>[];
  for (final r in (backup['plays'] as List? ?? const [])) {
    final id = await resolve(r);
    if (id != null) plays.add((id, (r as Map)['count'], r['last_played']));
  }

  await db.transaction((txn) async {
    for (final table in ['playlist_tracks', 'playlists', 'playlist_folders', 'favorites', 'plays', 'podcasts', 'podcast_progress']) {
      await txn.delete(table);
    }
    // Only replace the log when the backup has one (older backups don't).
    if (backup.containsKey('listening')) {
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
      final id = await txn.insert('playlists', {
        'name': pl['name'],
        'created_at': pl['created_at'],
        'cover': cover,
        'folder_id': folderIds[pl['folder']],
      });
      final ids = playlistIds[i];
      for (var j = 0; j < ids.length; j++) {
        await txn.insert('playlist_tracks', {'playlist_id': id, 'track_id': ids[j], 'position': j});
      }
      songs += ids.length;
    }
    for (final (id, at) in favorites) {
      await txn.insert('favorites', {'track_id': id, 'added_at': at}, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    for (final (id, count, last) in plays) {
      await txn.insert('plays', {'track_id': id, 'count': count, 'last_played': last}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    for (final table in ['podcasts', 'podcast_progress']) {
      for (final r in (backup[table] as List? ?? const []).cast<Map>()) {
        await txn.insert(table, r.cast<String, Object?>(), conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
    for (final r in (backup['download_history'] as List? ?? const []).cast<Map>()) {
      await txn.insert('download_history', r.cast<String, Object?>(), conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    final settings = (backup['settings'] as Map? ?? const {}).cast<String, Object?>();
    for (final e in settings.entries) {
      if (_privateSettings.contains(e.key) || e.value is! String) continue;
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
  app.notifyChanged();
  return RestoreReport(playlists: playlists.length, songs: songs, missing: missing.toList());
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
