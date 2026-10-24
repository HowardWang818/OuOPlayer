import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show sqfliteFfiInit, databaseFactoryFfi;

import '../../services/artists.dart';
import '../models/track.dart';

/// Thin sqflite wrapper. Every write emits on [changes] so providers can refresh.
class AppDatabase {
  AppDatabase._(this.db);

  /// Wraps an already open database (tests).
  AppDatabase.wrap(this.db);

  final Database db;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  void _notify() => _changes.add(null);

  /// For changes made straight on [db] (e.g. restoring a backup).
  void notifyChanged() => _notify();

  static Future<AppDatabase> open() async {
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'ouoplayer.db');
    final db = await openDatabase(path, version: schemaVersion, onUpgrade: migrate, onCreate: (db, _) async {
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
      await migrate(db, 1, schemaVersion);
    });
    // Previews from v0.3.0 were recorded as history; they don't belong there.
    await db.execute("DELETE FROM history WHERE track_id LIKE 'https://audio-ssl.itunes.apple.com/%'");
    // Keep play history bounded (v0.2.0 pre-release builds could flood it).
    await db.execute('DELETE FROM history WHERE rowid NOT IN (SELECT rowid FROM history ORDER BY played_at DESC LIMIT 1000)');
    return AppDatabase._(db);
  }

  static const schemaVersion = 6;

  /// Schema changes since version 1; existing data is kept.
  static Future<void> migrate(Database db, int from, int to) async {
    if (from < 2 && to >= 2) {
      // v0.5.0: custom playlist covers and playlist folders.
      await db.execute('ALTER TABLE playlists ADD COLUMN cover TEXT');
      await db.execute('ALTER TABLE playlists ADD COLUMN folder_id INTEGER');
      await db.execute('CREATE TABLE playlist_folders(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, created_at INTEGER)');
    }
    if (from < 3 && to >= 3) {
      // v0.6.0: which source (e.g. a YouTube video) became which file, so
      // playlist downloads can skip songs that are already there.
      await db.execute('CREATE TABLE download_history(source TEXT PRIMARY KEY, path TEXT NOT NULL, created_at INTEGER)');
    }
    if (from < 4 && to >= 4) {
      // v0.9.0: play counts for the smart playlists (history keeps only the
      // last 1000 plays), seeded from that history; podcast resume points.
      await db.execute('CREATE TABLE plays(track_id TEXT PRIMARY KEY, count INTEGER NOT NULL, last_played INTEGER)');
      await db.execute('INSERT INTO plays SELECT track_id, COUNT(*), MAX(played_at) FROM history GROUP BY track_id');
      await db.execute(
          'CREATE TABLE podcast_progress(uri TEXT PRIMARY KEY, position_ms INTEGER, duration_ms INTEGER, finished INTEGER, updated_at INTEGER)');
    }
    if (from < 5 && to >= 5) {
      // v0.11.0: indexes for big libraries (sorting, smart playlists,
      // playlists and likes lookups).
      for (final sql in [
        'CREATE INDEX IF NOT EXISTS idx_tracks_source ON tracks(source)',
        'CREATE INDEX IF NOT EXISTS idx_tracks_added ON tracks(added_at)',
        'CREATE INDEX IF NOT EXISTS idx_playlist_tracks_list ON playlist_tracks(playlist_id, position)',
        'CREATE INDEX IF NOT EXISTS idx_playlist_tracks_track ON playlist_tracks(track_id)',
        'CREATE INDEX IF NOT EXISTS idx_history_track ON history(track_id)',
        'CREATE INDEX IF NOT EXISTS idx_history_played ON history(played_at)',
        'CREATE INDEX IF NOT EXISTS idx_plays_count ON plays(count)',
      ]) {
        await db.execute(sql);
      }
    }
    if (from < 6 && to >= 6) {
      // v0.12.0: every play with how long it was really listened to, for the
      // statistics. The old history (last 1000 plays) comes along with the
      // song's length as an estimate.
      await db.execute('CREATE TABLE listening_log(id INTEGER PRIMARY KEY AUTOINCREMENT, track_id TEXT NOT NULL, '
          'played_at INTEGER NOT NULL, listened_ms INTEGER NOT NULL DEFAULT 0, source TEXT, estimated INTEGER NOT NULL DEFAULT 0)');
      await db.execute('CREATE INDEX idx_listening_played ON listening_log(played_at)');
      await db.execute('INSERT INTO listening_log(track_id, played_at, listened_ms, source, estimated) '
          'SELECT h.track_id, h.played_at, COALESCE(t.duration_ms, 0), t.source, 1 FROM history h LEFT JOIN tracks t ON t.id = h.track_id '
          'WHERE h.track_id IS NOT NULL');
    }
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
    final rows = await db.query('tracks', where: "source NOT IN ('url', 'podcast', 'preview', 'missing')", orderBy: orderBy);
    return rows.map(Track.fromMap).toList();
  }

  /// Random library songs (not streams/podcasts), skipping [exclude].
  Future<List<Track>> randomTracks(int count, {Set<String> exclude = const {}}) async {
    final rows = await db.query('tracks',
        where: "source NOT IN ('url', 'podcast', 'preview', 'missing')", orderBy: 'RANDOM()', limit: count + exclude.length);
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

  /// Saves edited details (編輯資訊) of a song already in the library.
  Future<void> updateTrackInfo(Track t) async {
    await db.update('tracks', {'title': t.title, 'artist': t.artist, 'album': t.album, 'art': t.art}, where: 'id = ?', whereArgs: [t.id]);
    _notify();
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

  /// Where removing these songs from the library takes them out of: the
  /// playlists holding them (name → rows), how many are liked, and the albums
  /// and artists left with no other song.
  Future<RemovalImpact> removalImpact(List<String> ids) async {
    final set = ids.toSet();
    final playlists = <String, int>{};
    var favorites = 0;
    final list = set.toList();
    for (var i = 0; i < list.length; i += 500) {
      final chunk = list.sublist(i, (i + 500).clamp(0, list.length));
      final marks = List.filled(chunk.length, '?').join(',');
      final rows = await db.rawQuery(
          'SELECT p.name AS name, COUNT(*) AS c FROM playlist_tracks pt JOIN playlists p ON p.id = pt.playlist_id '
          'WHERE pt.track_id IN ($marks) GROUP BY p.id ORDER BY p.name COLLATE NOCASE',
          chunk);
      for (final r in rows) {
        playlists.update(r['name'] as String, (v) => v + (r['c'] as int), ifAbsent: () => r['c'] as int);
      }
      final f = await db.rawQuery('SELECT COUNT(*) AS c FROM favorites WHERE track_id IN ($marks)', chunk);
      favorites += f.first['c'] as int;
    }
    final all = await tracks();
    final removed = all.where((t) => set.contains(t.id));
    final kept = all.where((t) => !set.contains(t.id));
    final keptAlbums = kept.map((t) => t.album).toSet();
    final dir = ArtistDirectory(all.map((t) => t.artist));
    final keptArtists = {for (final t in kept) ...dir.keysOf(t.artist)};
    return RemovalImpact(
      playlists: playlists,
      favorites: favorites,
      emptyAlbums: removed.map((t) => t.album).toSet().where((a) => !keptAlbums.contains(a) && a != '未知專輯').toList(),
      emptyArtists: [
        for (final e in {for (final t in removed) for (final n in dir.namesOf(t.artist)) dir.keyOf(n): n}.entries)
          if (!keptArtists.contains(e.key)) e.value,
      ],
    );
  }

  Future<List<Track>> search(String q) async {
    final like = '%$q%';
    final rows = await db.query('tracks',
        where: "source NOT IN ('url', 'podcast', 'preview', 'missing') AND (title LIKE ? OR artist LIKE ? OR album LIKE ?)",
        whereArgs: [like, like, like],
        orderBy: 'title COLLATE NOCASE',
        limit: 200);
    return rows.map(Track.fromMap).toList();
  }

  Future<List<Album>> albums() async {
    final rows = await db.rawQuery('''SELECT album, MAX(artist) AS artist, MAX(art) AS art, COUNT(*) AS c, MAX(added_at) AS a
      FROM tracks WHERE source NOT IN ('url', 'podcast', 'preview', 'missing') GROUP BY album ORDER BY album COLLATE NOCASE''');
    return rows
        .map((r) => Album(r['album'] as String? ?? '未知專輯', r['artist'] as String? ?? '', r['art'] as String?, r['c'] as int, (r['a'] as int?) ?? 0))
        .toList();
  }

  Future<List<Album>> recentAlbums({int limit = 12}) async {
    final rows = await db.rawQuery('''SELECT album, MAX(artist) AS artist, MAX(art) AS art, COUNT(*) AS c, MAX(added_at) AS a
      FROM tracks WHERE source NOT IN ('url', 'podcast', 'preview', 'missing') GROUP BY album ORDER BY a DESC LIMIT ?''', [limit]);
    return rows.map((r) => Album(r['album'] as String? ?? '未知專輯', r['artist'] as String? ?? '', r['art'] as String?, r['c'] as int)).toList();
  }

  /// One entry per artist, not per credit: 「YOASOBI」「YOASOBI, Ayase」 and
  /// 「Ayase, YOASOBI」 make YOASOBI and Ayase, each with all their songs;
  /// spellings are merged (see ArtistDirectory). Vocal synths are marked.
  Future<List<Artist>> artists() async {
    final rows = await db.rawQuery('''SELECT artist, art, added_at FROM tracks
      WHERE source NOT IN ('url', 'podcast', 'preview', 'missing')''');
    final dir = ArtistDirectory(rows.map((r) => r['artist'] as String? ?? ''));
    final byKey = <String, (String, String?, int, int, bool)>{};
    var unknown = 0;
    String? unknownArt;
    for (final r in rows) {
      final credit = r['artist'] as String? ?? '';
      final names = dir.namesOf(credit);
      if (names.isEmpty) {
        unknown++;
        unknownArt ??= r['art'] as String?;
        continue;
      }
      for (final name in names) {
        final k = dir.keyOf(name);
        final (n, art, count, added, virtual) = byKey[k] ?? (name, null, 0, 0, dir.isVirtual(name));
        byKey[k] = (n, art ?? r['art'] as String?, count + 1, max(added, (r['added_at'] as int?) ?? 0), virtual);
      }
    }
    final list = [
      for (final v in byKey.values) Artist(v.$1, v.$2, v.$3, v.$4, v.$5),
      if (unknown > 0) Artist('未知演出者', unknownArt, unknown),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  /// Tracks stored under [folder] (path prefix match; avoids LIKE wildcards in paths).
  Future<List<Track>> folderTracks(String folder) async {
    final prefix = _folderPrefix(folder);
    final rows = await db.query('tracks',
        where: "source NOT IN ('url', 'podcast', 'preview', 'missing') AND substr(uri, 1, ?) = ?",
        whereArgs: [prefix.length, prefix],
        orderBy: 'title COLLATE NOCASE');
    return rows.map(Track.fromMap).toList();
  }

  Future<int> folderTrackCount(String folder) async {
    final prefix = _folderPrefix(folder);
    final r = await db.rawQuery(
        "SELECT COUNT(*) AS c FROM tracks WHERE source NOT IN ('url', 'podcast', 'preview', 'missing') AND substr(uri, 1, ?) = ?",
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

  /// Every song crediting [artist] (any spelling, alone or with others).
  Future<List<Track>> artistTracks(String artist) async {
    final rows = await db.query('tracks',
        where: "source NOT IN ('url', 'podcast', 'preview', 'missing')", orderBy: 'album COLLATE NOCASE, track_no, title COLLATE NOCASE');
    final all = rows.map(Track.fromMap).toList();
    final dir = ArtistDirectory(all.map((t) => t.artist));
    if (artist == '未知演出者') return [for (final t in all) if (dir.namesOf(t.artist).isEmpty) t];
    final key = dir.keyOf(artist);
    return [for (final t in all) if (dir.keysOf(t.artist).contains(key)) t];
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
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('tracks', t.toMap(), conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.insert('history', {'track_id': t.id, 'played_at': now});
    // No UPSERT: older Android versions ship SQLite without it.
    await db.rawInsert('INSERT OR IGNORE INTO plays(track_id, count, last_played) VALUES(?, 0, ?)', [t.id, now]);
    await db.rawUpdate('UPDATE plays SET count = count + 1, last_played = ? WHERE track_id = ?', [now, t.id]);
    _notify();
  }

  // ---------- smart playlists ----------
  static const _music = "t.source NOT IN ('url', 'podcast', 'preview', 'missing')";

  Future<List<Track>> smartTracks(SmartList kind, {int limit = 100}) async {
    final monthAgo = DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch;
    final rows = switch (kind) {
      SmartList.mostPlayed => await db.rawQuery(
          'SELECT t.* FROM plays pl JOIN tracks t ON t.id = pl.track_id WHERE $_music ORDER BY pl.count DESC, pl.last_played DESC LIMIT ?',
          [limit]),
      SmartList.recentlyAdded => await db.rawQuery('SELECT t.* FROM tracks t WHERE $_music ORDER BY t.added_at DESC LIMIT ?', [limit]),
      SmartList.notPlayedLately => await db.rawQuery(
          'SELECT t.* FROM plays pl JOIN tracks t ON t.id = pl.track_id WHERE $_music AND pl.last_played < ? ORDER BY pl.last_played LIMIT ?',
          [monthAgo, limit]),
      SmartList.neverPlayed => await db.rawQuery(
          'SELECT t.* FROM tracks t LEFT JOIN plays pl ON pl.track_id = t.id WHERE $_music AND pl.track_id IS NULL ORDER BY t.added_at DESC LIMIT ?',
          [limit]),
    };
    return rows.map(Track.fromMap).toList();
  }

  /// track id → times played.
  Future<Map<String, int>> playCounts() async {
    final rows = await db.query('plays', columns: ['track_id', 'count']);
    return {for (final r in rows) r['track_id'] as String: r['count'] as int};
  }

  // ---------- clearing play data ----------
  /// Removes the chosen kinds of play data; songs, playlists and likes stay.
  Future<void> clearPlayData(Set<PlayData> kinds) async {
    await db.transaction((txn) async {
      for (final k in kinds) {
        await txn.delete(switch (k) {
          PlayData.listening => 'listening_log',
          PlayData.playCounts => 'plays',
          PlayData.recent => 'history',
          PlayData.podcastProgress => 'podcast_progress',
        });
      }
    });
    _notify();
  }

  // ---------- listening log ----------
  /// Starts a log entry for a play; returns its id for [updateListening].
  Future<int> startListening(Track t, DateTime at) => db.insert('listening_log', {
        'track_id': t.id,
        'played_at': at.millisecondsSinceEpoch,
        'listened_ms': 0,
        'source': t.source,
      });

  Future<void> updateListening(int id, Duration listened) =>
      db.update('listening_log', {'listened_ms': listened.inMilliseconds}, where: 'id = ?', whereArgs: [id]);

  /// Plays from [from] (inclusive) to [to] (exclusive), oldest first.
  Future<List<ListeningEntry>> listening(DateTime from, DateTime to) async {
    final rows = await db.query('listening_log',
        where: 'played_at >= ? AND played_at < ?', whereArgs: [from.millisecondsSinceEpoch, to.millisecondsSinceEpoch], orderBy: 'played_at');
    return [
      for (final r in rows)
        ListeningEntry(
          trackId: r['track_id'] as String,
          playedAt: DateTime.fromMillisecondsSinceEpoch(r['played_at'] as int),
          listened: Duration(milliseconds: r['listened_ms'] as int),
          source: r['source'] as String?,
          estimated: r['estimated'] == 1,
        ),
    ];
  }

  // ---------- podcast progress ----------
  /// [notify] refreshes the episode lists; the periodic saves while playing
  /// skip it so the whole UI isn't rebuilt every few seconds.
  Future<void> savePodcastProgress(String uri, Duration position, Duration? duration, {bool finished = false, bool notify = true}) async {
    await db.insert(
      'podcast_progress',
      {
        'uri': uri,
        'position_ms': position.inMilliseconds,
        'duration_ms': duration?.inMilliseconds,
        'finished': finished ? 1 : 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (notify) _notify();
  }

  /// uri → (position, finished) for podcast episodes started before.
  Future<Map<String, ({Duration position, Duration? duration, bool finished})>> podcastProgress() async {
    final rows = await db.query('podcast_progress');
    return {
      for (final r in rows)
        r['uri'] as String: (
          position: Duration(milliseconds: (r['position_ms'] as int?) ?? 0),
          duration: r['duration_ms'] == null ? null : Duration(milliseconds: r['duration_ms'] as int),
          finished: r['finished'] == 1,
        ),
    };
  }

  Future<void> clearPodcastProgress(String uri) async {
    await db.delete('podcast_progress', where: 'uri = ?', whereArgs: [uri]);
    _notify();
  }

  Future<List<Track>> recentlyPlayed({int limit = 20}) async {
    final rows = await db.rawQuery('''SELECT t.*, MAX(h.played_at) AS p FROM history h JOIN tracks t ON t.id = h.track_id
      GROUP BY h.track_id ORDER BY p DESC LIMIT ?''', [limit]);
    return rows.map(Track.fromMap).toList();
  }

  // ---------- playlists ----------
  /// All playlists, or only those in [folder] / outside any folder ([topLevel]).
  Future<List<Playlist>> playlists({int? folder, bool topLevel = false}) async {
    final where = folder != null ? 'WHERE p.folder_id = ?' : (topLevel ? 'WHERE p.folder_id IS NULL' : '');
    // Placeholders for songs not on the device count apart (「缺 N 首」).
    final rows = await db.rawQuery('''SELECT p.id, p.name, p.cover, p.folder_id,
      COUNT(CASE WHEN t0.source IS NULL OR t0.source != 'missing' THEN pt.track_id END) AS c,
      COUNT(CASE WHEN t0.source = 'missing' THEN 1 END) AS m,
      (SELECT t.art FROM playlist_tracks x JOIN tracks t ON t.id = x.track_id WHERE x.playlist_id = p.id AND t.art IS NOT NULL ORDER BY x.position LIMIT 1) AS art
      FROM playlists p LEFT JOIN playlist_tracks pt ON pt.playlist_id = p.id LEFT JOIN tracks t0 ON t0.id = pt.track_id
      $where GROUP BY p.id ORDER BY p.created_at DESC''',
        [if (folder != null) folder]);
    return rows
        .map((r) => Playlist(
              r['id'] as int,
              r['name'] as String,
              r['c'] as int,
              (r['cover'] as String?) ?? r['art'] as String?,
              cover: r['cover'] as String?,
              folderId: r['folder_id'] as int?,
              missing: (r['m'] as int?) ?? 0,
            ))
        .toList();
  }

  Future<void> setPlaylistCover(int id, String? cover) async {
    await db.update('playlists', {'cover': cover}, where: 'id = ?', whereArgs: [id]);
    _notify();
  }

  Future<void> setPlaylistFolder(int id, int? folderId) async {
    await db.update('playlists', {'folder_id': folderId}, where: 'id = ?', whereArgs: [id]);
    _notify();
  }

  // ---------- download history ----------
  Future<void> recordDownload(String source, String path) async {
    await db.insert('download_history', {'source': source, 'path': path, 'created_at': DateTime.now().millisecondsSinceEpoch},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> downloadedPath(String source) async {
    final rows = await db.query('download_history', where: 'source = ?', whereArgs: [source], limit: 1);
    return rows.isEmpty ? null : rows.first['path'] as String;
  }

  // ---------- playlist folders ----------
  Future<List<PlaylistFolder>> folders() async {
    final rows = await db.query('playlist_folders', orderBy: 'created_at DESC');
    final all = await playlists();
    return [
      for (final r in rows)
        () {
          final inside = all.where((p) => p.folderId == r['id']).toList();
          return PlaylistFolder(r['id'] as int, r['name'] as String, inside.length,
              [for (final p in inside) if (p.art != null) p.art!].take(4).toList());
        }(),
    ];
  }

  Future<int> createFolder(String name) async {
    final id = await db.insert('playlist_folders', {'name': name, 'created_at': DateTime.now().millisecondsSinceEpoch});
    _notify();
    return id;
  }

  Future<void> renameFolder(int id, String name) async {
    await db.update('playlist_folders', {'name': name}, where: 'id = ?', whereArgs: [id]);
    _notify();
  }

  /// Deletes the folder only; its playlists move back to the top level.
  Future<void> deleteFolder(int id) async {
    await db.update('playlists', {'folder_id': null}, where: 'folder_id = ?', whereArgs: [id]);
    await db.delete('playlist_folders', where: 'id = ?', whereArgs: [id]);
    _notify();
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

  /// Appends songs that aren't in the playlist yet (each song appears once),
  /// or all of them with [allowDuplicates]. Returns how many were added.
  Future<int> addToPlaylist(int id, List<Track> tracks, {bool allowDuplicates = false}) async {
    final r = await db.rawQuery('SELECT COALESCE(MAX(position), -1) AS m FROM playlist_tracks WHERE playlist_id = ?', [id]);
    var pos = (r.first['m'] as int) + 1;
    final have = await _playlistTrackIds(id);
    final batch = db.batch();
    var added = 0;
    for (final t in tracks) {
      if (!have.add(t.id) && !allowDuplicates) continue;
      batch.insert('tracks', t.toMap(), conflictAlgorithm: ConflictAlgorithm.ignore);
      batch.insert('playlist_tracks', {'playlist_id': id, 'track_id': t.id, 'position': pos++});
      added++;
    }
    await batch.commit(noResult: true);
    _notify();
    return added;
  }

  Future<Set<String>> _playlistTrackIds(int id) async {
    final rows = await db.query('playlist_tracks', columns: ['track_id'], where: 'playlist_id = ?', whereArgs: [id]);
    return {for (final r in rows) r['track_id'] as String};
  }

  /// Removes repeated songs from a playlist, keeping each song's first
  /// occurrence and the order. Returns how many rows were removed.
  Future<int> removePlaylistDuplicates(int id) async {
    final tracks = await playlistTracks(id);
    final unique = withoutDuplicates(tracks);
    final removed = tracks.length - unique.length;
    if (removed > 0) await _rewritePlaylist(id, unique);
    return removed;
  }

  Future<void> removeFromPlaylist(int id, int index) async {
    final tracks = await playlistTracks(id);
    if (index < 0 || index >= tracks.length) return;
    tracks.removeAt(index);
    await _rewritePlaylist(id, tracks);
  }

  /// Position after the last song of a playlist.
  Future<int> nextPlaylistPosition(int id) async {
    final r = await db.rawQuery('SELECT COALESCE(MAX(position), -1) AS m FROM playlist_tracks WHERE playlist_id = ?', [id]);
    return (r.first['m'] as int) + 1;
  }

  /// Puts a song at a given position (gaps are fine: the list is ordered by
  /// position), so songs downloaded in parallel keep the source order.
  /// Does nothing if the song is already in the playlist; returns whether it
  /// was added.
  Future<bool> addToPlaylistAt(int id, Track track, int position) async {
    final have = await db.query('playlist_tracks',
        columns: ['track_id'], where: 'playlist_id = ? AND track_id = ?', whereArgs: [id, track.id], limit: 1);
    if (have.isNotEmpty) return false;
    await db.insert('tracks', track.toMap(), conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.insert('playlist_tracks', {'playlist_id': id, 'track_id': track.id, 'position': position});
    _notify();
    return true;
  }

  /// Removes several rows (by position) from a playlist at once.
  Future<void> removeFromPlaylistAt(int id, List<int> indexes) async {
    final tracks = await playlistTracks(id);
    final drop = indexes.toSet();
    await _rewritePlaylist(id, [for (var i = 0; i < tracks.length; i++) if (!drop.contains(i)) tracks[i]]);
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

/// [tracks] with each song kept only the first time it appears.
List<Track> withoutDuplicates(List<Track> tracks) {
  final seen = <String>{};
  return [for (final t in tracks) if (seen.add(t.id)) t];
}

/// See [AppDatabase.removalImpact].
class RemovalImpact {
  const RemovalImpact({this.playlists = const {}, this.favorites = 0, this.emptyAlbums = const [], this.emptyArtists = const []});
  final Map<String, int> playlists;
  final int favorites;
  final List<String> emptyAlbums;
  final List<String> emptyArtists;
}

/// Playlists made from the play counts; they update by themselves.
enum SmartList {
  mostPlayed('最常播放', '播放次數最多的歌'),
  recentlyAdded('最近加入', '最新加入音樂庫的歌'),
  notPlayedLately('很久沒聽', '超過 30 天沒播放的歌'),
  neverPlayed('從沒播過', '還沒播放過的歌');

  const SmartList(this.label, this.description);
  final String label;
  final String description;
}

/// One play in the listening log.
class ListeningEntry {
  const ListeningEntry({required this.trackId, required this.playedAt, required this.listened, this.source, this.estimated = false});
  final String trackId;
  final DateTime playedAt;
  final Duration listened;
  final String? source;

  /// From the history before v0.12.0: the song's length, not measured.
  final bool estimated;
}

/// What 清除播放資料 can remove.
enum PlayData {
  listening('收聽統計紀錄', '統計頁和年度回顧的資料'),
  playCounts('播放次數', '智慧播放清單「最常播放」「很久沒聽」「從沒播過」的依據'),
  recent('最近播放', '首頁和車上的「最近播放」'),
  podcastProgress('Podcast 收聽進度', '每一集聽到哪裡、是否已聽完');

  const PlayData(this.label, this.description);
  final String label;
  final String description;
}
