import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show sqfliteFfiInit, databaseFactoryFfi;

import '../models/track.dart';

/// Thin sqflite wrapper. Every write emits on [changes] so providers can refresh.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  void _notify() => _changes.add(null);

  static Future<AppDatabase> open() async {
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'ouoplayer.db');
    final db = await openDatabase(path, version: 1, onCreate: (db, _) async {
      await db.execute('''CREATE TABLE tracks(
        id TEXT PRIMARY KEY, uri TEXT NOT NULL, title TEXT NOT NULL, artist TEXT, album TEXT,
        duration_ms INTEGER, art TEXT, source TEXT, track_no INTEGER, added_at INTEGER)''');
      await db.execute('CREATE INDEX idx_tracks_album ON tracks(album)');
      await db.execute('CREATE INDEX idx_tracks_artist ON tracks(artist)');
      await db.execute('CREATE TABLE playlists(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, created_at INTEGER)');
      await db.execute('CREATE TABLE playlist_tracks(playlist_id INTEGER, track_id TEXT, position INTEGER)');
      await db.execute('CREATE TABLE favorites(track_id TEXT PRIMARY KEY, added_at INTEGER)');
      await db.execute('CREATE TABLE history(track_id TEXT, played_at INTEGER)');
      await db.execute('CREATE TABLE podcasts(feed_url TEXT PRIMARY KEY, title TEXT, author TEXT, image TEXT, added_at INTEGER)');
      await db.execute('CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT)');
    });
    // Keep play history bounded (v0.2.0 pre-release builds could flood it).
    await db.execute('DELETE FROM history WHERE rowid NOT IN (SELECT rowid FROM history ORDER BY played_at DESC LIMIT 1000)');
    return AppDatabase._(db);
  }

  // ---------- settings ----------
  Future<Map<String, String>> allSettings() async {
    final rows = await db.query('settings');
    return {for (final r in rows) r['key'] as String: (r['value'] as String?) ?? ''};
  }

  Future<void> setSetting(String key, String value) =>
      db.insert('settings', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);

  // ---------- tracks ----------
  Future<void> upsertTracks(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    final batch = db.batch();
    for (final t in tracks) {
      batch.insert('tracks', t.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
    _notify();
  }

  Future<Set<String>> trackIds() async {
    final rows = await db.query('tracks', columns: ['id']);
    return rows.map((r) => r['id'] as String).toSet();
  }

  Future<List<Track>> tracks({String orderBy = 'title COLLATE NOCASE'}) async {
    final rows = await db.query('tracks', where: "source != 'url' AND source != 'podcast'", orderBy: orderBy);
    return rows.map(Track.fromMap).toList();
  }

  /// Random library songs (not streams/podcasts), skipping [exclude].
  Future<List<Track>> randomTracks(int count, {Set<String> exclude = const {}}) async {
    final rows = await db.query('tracks',
        where: "source != 'url' AND source != 'podcast'", orderBy: 'RANDOM()', limit: count + exclude.length);
    return rows.map(Track.fromMap).where((t) => !exclude.contains(t.id) && t.fileExists).take(count).toList();
  }

  Future<Track?> track(String id) async {
    final rows = await db.query('tracks', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Track.fromMap(rows.first);
  }

  Future<List<Track>> tracksByIds(List<String> ids) async {
    if (ids.isEmpty) return [];
    final rows = await db.query('tracks', where: 'id IN (${List.filled(ids.length, '?').join(',')})', whereArgs: ids);
    final byId = {for (final r in rows) r['id'] as String: Track.fromMap(r)};
    return [for (final id in ids) if (byId[id] != null) byId[id]!];
  }

  Future<void> deleteTracks(Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    final marks = List.filled(list.length, '?').join(',');
    await db.delete('tracks', where: 'id IN ($marks)', whereArgs: list);
    await db.delete('playlist_tracks', where: 'track_id IN ($marks)', whereArgs: list);
    await db.delete('favorites', where: 'track_id IN ($marks)', whereArgs: list);
    _notify();
  }

  Future<List<Track>> search(String q) async {
    final like = '%$q%';
    final rows = await db.query('tracks',
        where: "source != 'url' AND source != 'podcast' AND (title LIKE ? OR artist LIKE ? OR album LIKE ?)",
        whereArgs: [like, like, like],
        orderBy: 'title COLLATE NOCASE',
        limit: 200);
    return rows.map(Track.fromMap).toList();
  }

  Future<List<Album>> albums() async {
    final rows = await db.rawQuery('''SELECT album, MAX(artist) AS artist, MAX(art) AS art, COUNT(*) AS c
      FROM tracks WHERE source != 'url' AND source != 'podcast' GROUP BY album ORDER BY album COLLATE NOCASE''');
    return rows.map((r) => Album(r['album'] as String? ?? '未知專輯', r['artist'] as String? ?? '', r['art'] as String?, r['c'] as int)).toList();
  }

  Future<List<Album>> recentAlbums({int limit = 12}) async {
    final rows = await db.rawQuery('''SELECT album, MAX(artist) AS artist, MAX(art) AS art, COUNT(*) AS c, MAX(added_at) AS a
      FROM tracks WHERE source != 'url' AND source != 'podcast' GROUP BY album ORDER BY a DESC LIMIT ?''', [limit]);
    return rows.map((r) => Album(r['album'] as String? ?? '未知專輯', r['artist'] as String? ?? '', r['art'] as String?, r['c'] as int)).toList();
  }

  Future<List<Artist>> artists() async {
    final rows = await db.rawQuery('''SELECT artist, MAX(art) AS art, COUNT(*) AS c
      FROM tracks WHERE source != 'url' AND source != 'podcast' GROUP BY artist ORDER BY artist COLLATE NOCASE''');
    return rows.map((r) => Artist(r['artist'] as String? ?? '未知演出者', r['art'] as String?, r['c'] as int)).toList();
  }

  /// Tracks stored under [folder] (path prefix match; avoids LIKE wildcards in paths).
  Future<List<Track>> folderTracks(String folder) async {
    final prefix = _folderPrefix(folder);
    final rows = await db.query('tracks',
        where: "source != 'url' AND source != 'podcast' AND substr(uri, 1, ?) = ?",
        whereArgs: [prefix.length, prefix],
        orderBy: 'title COLLATE NOCASE');
    return rows.map(Track.fromMap).toList();
  }

  Future<int> folderTrackCount(String folder) async {
    final prefix = _folderPrefix(folder);
    final r = await db.rawQuery(
        "SELECT COUNT(*) AS c FROM tracks WHERE source != 'url' AND source != 'podcast' AND substr(uri, 1, ?) = ?",
        [prefix.length, prefix]);
    return r.first['c'] as int;
  }

  static String _folderPrefix(String folder) {
    final sep = Platform.isWindows ? r'\' : '/';
    return folder.endsWith(sep) ? folder : '$folder$sep';
  }

  Future<List<Track>> albumTracks(String album) async {
    final rows = await db.query('tracks', where: 'album = ?', whereArgs: [album], orderBy: 'track_no, title COLLATE NOCASE');
    return rows.map(Track.fromMap).toList();
  }

  Future<List<Track>> artistTracks(String artist) async {
    final rows = await db.query('tracks', where: 'artist = ?', whereArgs: [artist], orderBy: 'album, track_no, title');
    return rows.map(Track.fromMap).toList();
  }

  // ---------- favorites ----------
  Future<Set<String>> favoriteIds() async {
    final rows = await db.query('favorites', columns: ['track_id']);
    return rows.map((r) => r['track_id'] as String).toSet();
  }

  Future<List<Track>> favorites() async {
    final rows = await db.rawQuery('SELECT t.* FROM favorites f JOIN tracks t ON t.id = f.track_id ORDER BY f.added_at DESC');
    return rows.map(Track.fromMap).toList();
  }

  Future<void> setFavorite(Track t, bool fav) async {
    if (fav) {
      await db.insert('tracks', t.toMap(), conflictAlgorithm: ConflictAlgorithm.ignore);
      await db.insert('favorites', {'track_id': t.id, 'added_at': DateTime.now().millisecondsSinceEpoch},
          conflictAlgorithm: ConflictAlgorithm.replace);
    } else {
      await db.delete('favorites', where: 'track_id = ?', whereArgs: [t.id]);
    }
    _notify();
  }

  // ---------- history ----------
  Future<void> addHistory(Track t) async {
    await db.insert('tracks', t.toMap(), conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.insert('history', {'track_id': t.id, 'played_at': DateTime.now().millisecondsSinceEpoch});
    _notify();
  }

  Future<List<Track>> recentlyPlayed({int limit = 20}) async {
    final rows = await db.rawQuery('''SELECT t.*, MAX(h.played_at) AS p FROM history h JOIN tracks t ON t.id = h.track_id
      GROUP BY h.track_id ORDER BY p DESC LIMIT ?''', [limit]);
    return rows.map(Track.fromMap).toList();
  }

  // ---------- playlists ----------
  Future<List<Playlist>> playlists() async {
    final rows = await db.rawQuery('''SELECT p.id, p.name, COUNT(pt.track_id) AS c,
      (SELECT t.art FROM playlist_tracks x JOIN tracks t ON t.id = x.track_id WHERE x.playlist_id = p.id AND t.art IS NOT NULL ORDER BY x.position LIMIT 1) AS art
      FROM playlists p LEFT JOIN playlist_tracks pt ON pt.playlist_id = p.id GROUP BY p.id ORDER BY p.created_at DESC''');
    return rows.map((r) => Playlist(r['id'] as int, r['name'] as String, r['c'] as int, r['art'] as String?)).toList();
  }

  Future<int> createPlaylist(String name) async {
    final id = await db.insert('playlists', {'name': name, 'created_at': DateTime.now().millisecondsSinceEpoch});
    _notify();
    return id;
  }

  Future<void> renamePlaylist(int id, String name) async {
    await db.update('playlists', {'name': name}, where: 'id = ?', whereArgs: [id]);
    _notify();
  }

  Future<void> deletePlaylist(int id) async {
    await db.delete('playlists', where: 'id = ?', whereArgs: [id]);
    await db.delete('playlist_tracks', where: 'playlist_id = ?', whereArgs: [id]);
    _notify();
  }

  Future<List<Track>> playlistTracks(int id) async {
    final rows = await db.rawQuery(
        'SELECT t.* FROM playlist_tracks pt JOIN tracks t ON t.id = pt.track_id WHERE pt.playlist_id = ? ORDER BY pt.position',
        [id]);
    return rows.map(Track.fromMap).toList();
  }

  Future<void> addToPlaylist(int id, List<Track> tracks) async {
    final r = await db.rawQuery('SELECT COALESCE(MAX(position), -1) AS m FROM playlist_tracks WHERE playlist_id = ?', [id]);
    var pos = (r.first['m'] as int) + 1;
    final batch = db.batch();
    for (final t in tracks) {
      batch.insert('tracks', t.toMap(), conflictAlgorithm: ConflictAlgorithm.ignore);
      batch.insert('playlist_tracks', {'playlist_id': id, 'track_id': t.id, 'position': pos++});
    }
    await batch.commit(noResult: true);
    _notify();
  }

  Future<void> removeFromPlaylist(int id, int index) async {
    final tracks = await playlistTracks(id);
    if (index < 0 || index >= tracks.length) return;
    tracks.removeAt(index);
    await _rewritePlaylist(id, tracks);
  }

  Future<void> reorderPlaylist(int id, int oldIndex, int newIndex) async {
    final tracks = await playlistTracks(id);
    final t = tracks.removeAt(oldIndex);
    tracks.insert(newIndex.clamp(0, tracks.length), t);
    await _rewritePlaylist(id, tracks);
  }

  Future<void> _rewritePlaylist(int id, List<Track> tracks) async {
    await db.transaction((txn) async {
      await txn.delete('playlist_tracks', where: 'playlist_id = ?', whereArgs: [id]);
      for (var i = 0; i < tracks.length; i++) {
        await txn.insert('playlist_tracks', {'playlist_id': id, 'track_id': tracks[i].id, 'position': i});
      }
    });
    _notify();
  }

  // ---------- podcasts ----------
  Future<List<Podcast>> podcasts() async {
    final rows = await db.query('podcasts', orderBy: 'added_at DESC');
    return rows
        .map((r) => Podcast(r['feed_url'] as String, r['title'] as String? ?? '', r['author'] as String? ?? '', r['image'] as String?))
        .toList();
  }

  Future<void> savePodcast(Podcast p) async {
    await db.insert(
        'podcasts',
        {'feed_url': p.feedUrl, 'title': p.title, 'author': p.author, 'image': p.image, 'added_at': DateTime.now().millisecondsSinceEpoch},
        conflictAlgorithm: ConflictAlgorithm.replace);
    _notify();
  }

  Future<void> deletePodcast(String feedUrl) async {
    await db.delete('podcasts', where: 'feed_url = ?', whereArgs: [feedUrl]);
    _notify();
  }
}
