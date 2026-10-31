import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show sqfliteFfiInit, databaseFactoryFfi;

import '../../services/artists.dart';
import '../../services/loudness.dart' show SongLoudness;
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

  /// Playlist sync: told about the user's own playlist changes (never the
  /// ones sync itself makes, which go through [setPlaylistRows]).
  SyncHooks? syncHooks;

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

  static const schemaVersion = 12;

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
    if (from < 7 && to >= 7) {
      // v1.3.0: songs 找歌詞 / 找封面 / 找日文歌名 found nothing for, skipped
      // the next time a whole list is looked up.
      await db.execute('CREATE TABLE lookup_misses(kind TEXT NOT NULL, track_id TEXT NOT NULL, at INTEGER, PRIMARY KEY(kind, track_id))');
    }
    if (from < 8 && to >= 8) {
      // v1.5.0: each song's measured loudness (LUFS) and peak, for one fixed
      // 音量平衡 gain per song.
      await db.execute('CREATE TABLE track_loudness(track_id TEXT PRIMARY KEY, lufs REAL NOT NULL, peak REAL NOT NULL, at INTEGER)');
    }
    if (from < 9 && to >= 9) {
      // v1.6.0: playlists and their folders get an id that is the same on
      // every device, for Google Drive sync.
      await db.execute('ALTER TABLE playlists ADD COLUMN uid TEXT');
      await db.execute('ALTER TABLE playlist_folders ADD COLUMN uid TEXT');
    }
    if (from < 10 && to >= 10) {
      // v1.7.0: plays brought in from another device (Google Drive sync) say
      // which one; this device's own plays have none.
      await db.execute('ALTER TABLE listening_log ADD COLUMN origin TEXT');
    }
    if (from < 11 && to >= 11) {
      // v1.11.0 playlist sync: which playlists are synced, an id per playlist
      // entry (the same on every device), and each synced list's state.
      await db.execute('ALTER TABLE playlists ADD COLUMN synced INTEGER NOT NULL DEFAULT 0');
      await db.execute('ALTER TABLE playlist_tracks ADD COLUMN item_id TEXT');
      await db.execute('CREATE TABLE sync_lists(sid TEXT PRIMARY KEY, state TEXT NOT NULL)');
    }
    if (from < 12 && to >= 12) {
      // v1.12.0 sync of song details and plays: the latest edit of each song
      // (root: the song's first title|artist, the same on every device), a
      // play's id on the device it came from, and songs only played there.
      await db.execute('CREATE TABLE track_edits(track_id TEXT PRIMARY KEY, root TEXT NOT NULL, root_ms INTEGER, '
          'title TEXT, artist TEXT, album TEXT, cover TEXT, at INTEGER NOT NULL, device TEXT NOT NULL)');
      await db.execute('ALTER TABLE listening_log ADD COLUMN remote_id TEXT');
      await db.execute('CREATE UNIQUE INDEX idx_listening_remote ON listening_log(remote_id)');
      await db.execute('CREATE TABLE remote_songs(id TEXT PRIMARY KEY, title TEXT NOT NULL, artist TEXT, album TEXT, duration_ms INTEGER)');
    }
  }

  // ---------- loudness ----------
  Future<SongLoudness?> loudness(String trackId) async {
    final rows = await db.query('track_loudness', where: 'track_id = ?', whereArgs: [trackId], limit: 1);
    if (rows.isEmpty) return null;
    return SongLoudness((rows.first['lufs'] as num).toDouble(), (rows.first['peak'] as num).toDouble());
  }

  Future<Set<String>> loudnessIds() async =>
      {for (final r in await db.query('track_loudness', columns: ['track_id'])) r['track_id'] as String};

  Future<void> setLoudness(String trackId, double lufs, double peak) => db.insert(
      'track_loudness', {'track_id': trackId, 'lufs': lufs, 'peak': peak, 'at': DateTime.now().millisecondsSinceEpoch},
      conflictAlgorithm: ConflictAlgorithm.replace);

  // ---------- lookup misses ----------
  Future<Set<String>> lookupMisses(String kind) async {
    final rows = await db.query('lookup_misses', columns: ['track_id'], where: 'kind = ?', whereArgs: [kind]);
    return {for (final r in rows) r['track_id'] as String};
  }

  /// Remembers (or forgets) that [kind] found nothing for the song.
  Future<void> setLookupMiss(String kind, String trackId, bool missed) => missed
      ? db.insert('lookup_misses', {'kind': kind, 'track_id': trackId, 'at': DateTime.now().millisecondsSinceEpoch},
          conflictAlgorithm: ConflictAlgorithm.replace)
      : db.delete('lookup_misses', where: 'kind = ? AND track_id = ?', whereArgs: [kind, trackId]);

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
    final before = await track(t.id);
    await db.update('tracks', {'title': t.title, 'artist': t.artist, 'album': t.album, 'art': t.art}, where: 'id = ?', whereArgs: [t.id]);
    if (before != null && (before.title != t.title || before.artist != t.artist || before.album != t.album || before.art != t.art)) {
      await syncHooks?.trackEdited(before, t);
    }
    _notify();
  }

  /// Songs whose files moved (old path → new path): the song keeps its
  /// playlists, like, play counts, listening log and download record.
  Future<void> moveTrackPaths(Map<String, String> moved) async {
    if (moved.isEmpty) return;
    await db.transaction((txn) async {
      for (final e in moved.entries) {
        if (e.key == e.value) continue;
        await txn.update('tracks', {'id': e.value, 'uri': e.value}, where: 'id = ?', whereArgs: [e.key]);
        for (final table in ['playlist_tracks', 'history', 'listening_log', 'track_edits']) {
          await txn.update(table, {'track_id': e.value}, where: 'track_id = ?', whereArgs: [e.key]);
        }
        for (final table in ['favorites', 'plays']) {
          await txn.update(table, {'track_id': e.value}, where: 'track_id = ?', whereArgs: [e.key], conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await txn.update('download_history', {'path': e.value}, where: 'path = ?', whereArgs: [e.key]);
      }
    });
    _notify();
  }

  Future<void> deleteTracks(Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    final marks = List.filled(list.length, '?').join(',');
    final gone = [for (final r in await db.query('tracks', columns: ['title', 'artist'], where: 'id IN ($marks)', whereArgs: list)) (r['title'] as String, (r['artist'] as String?) ?? '')];
    await db.delete('tracks', where: 'id IN ($marks)', whereArgs: list);
    await db.delete('playlist_tracks', where: 'track_id IN ($marks)', whereArgs: list);
    await db.delete('favorites', where: 'track_id IN ($marks)', whereArgs: list);
    await db.delete('track_edits', where: 'track_id IN ($marks)', whereArgs: list);
    // Songs leaving this device's library isn't a playlist action: synced
    // playlists keep them (greyed), and sync doesn't fetch them back.
    await syncHooks?.songsRemoved(gone);
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
    final keptArtists = {for (final t in kept) dir.primaryKey(t.artist)};
    return RemovalImpact(
      playlists: playlists,
      favorites: favorites,
      emptyAlbums: removed.map((t) => t.album).toSet().where((a) => !keptAlbums.contains(a) && a != '未知專輯').toList(),
      emptyArtists: [
        for (final e in {for (final t in removed) if (dir.primary(t.artist) != null) dir.keyOf(dir.primary(t.artist)!): dir.primary(t.artist)!}.entries)
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

  /// One entry per artist, by the first artist credited: 「YOASOBI, Ayase」
  /// counts for YOASOBI only; spellings are merged (see ArtistDirectory).
  Future<List<Artist>> artists() async {
    final rows = await db.rawQuery('''SELECT artist, art, added_at FROM tracks
      WHERE source NOT IN ('url', 'podcast', 'preview', 'missing')''');
    final dir = ArtistDirectory(rows.map((r) => r['artist'] as String? ?? ''));
    final byKey = <String, (String, String?, int, int)>{};
    for (final r in rows) {
      final name = dir.primary(r['artist'] as String? ?? '') ?? '未知演出者';
      final k = name == '未知演出者' ? '' : dir.keyOf(name);
      final (n, art, count, added) = byKey[k] ?? (name, null, 0, 0);
      byKey[k] = (n, art ?? r['art'] as String?, count + 1, max(added, (r['added_at'] as int?) ?? 0));
    }
    return [for (final v in byKey.values) Artist(v.$1, v.$2, v.$3, v.$4)]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
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

  /// The songs listed under [artist]: those crediting it first (any spelling).
  Future<List<Track>> artistTracks(String artist) async {
    final rows = await db.query('tracks',
        where: "source NOT IN ('url', 'podcast', 'preview', 'missing')", orderBy: 'album COLLATE NOCASE, track_no, title COLLATE NOCASE');
    final all = rows.map(Track.fromMap).toList();
    final dir = ArtistDirectory(all.map((t) => t.artist));
    if (artist == '未知演出者') return [for (final t in all) if (dir.primary(t.artist) == null) t];
    final key = dir.keyOf(artist);
    return [for (final t in all) if (dir.primaryKey(t.artist) == key) t];
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
    await syncHooks?.likesEdited();
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

  /// Ids of the songs really listened to: 30 seconds in one play, or 90% of a
  /// shorter song. A song skipped straight away stays unheard.
  Future<Set<String>> heardTracks() async {
    final rows = await db.rawQuery('SELECT DISTINCT l.track_id AS id FROM listening_log l LEFT JOIN tracks t ON t.id = l.track_id '
        'WHERE l.listened_ms >= MIN(30000, COALESCE(NULLIF(t.duration_ms, 0) * 9 / 10, 30000))');
    return {for (final r in rows) r['id'] as String};
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

  /// Songs only played on another device (sync): id → a stand-in song.
  Future<Map<String, Track>> remoteSongs() async => {
        for (final r in await db.query('remote_songs'))
          r['id'] as String: Track(
            id: r['id'] as String,
            uri: '',
            title: r['title'] as String,
            artist: (r['artist'] as String?) ?? '未知演出者',
            album: (r['album'] as String?) ?? '未知專輯',
            durationMs: r['duration_ms'] as int?,
            source: TrackSource.missing,
            addedAt: 0,
          ),
      };

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
    await syncHooks?.playlistEdited(id);
    _notify();
  }

  Future<void> deletePlaylist(int id) async {
    final row = await db.query('playlists', columns: ['uid', 'synced'], where: 'id = ?', whereArgs: [id]);
    await db.delete('playlists', where: 'id = ?', whereArgs: [id]);
    await db.delete('playlist_tracks', where: 'playlist_id = ?', whereArgs: [id]);
    if (row.isNotEmpty && row.first['synced'] == 1) await syncHooks?.playlistDeleted(row.first['uid'] as String?);
    _notify();
  }

  /// A playlist's rows in order: (song id, entry id or null).
  Future<List<(String, String?)>> playlistRows(int id) async {
    final rows = await db.query('playlist_tracks', columns: ['track_id', 'item_id'], where: 'playlist_id = ?', whereArgs: [id], orderBy: 'position');
    return [for (final r in rows) (r['track_id'] as String, r['item_id'] as String?)];
  }

  /// Sync: the playlist becomes exactly [rows] (song id, entry id). Not a
  /// user action, so not reported to [syncHooks].
  Future<void> setPlaylistRows(int id, List<(String, String?)> rows) async {
    await db.transaction((txn) async {
      await txn.delete('playlist_tracks', where: 'playlist_id = ?', whereArgs: [id]);
      for (var i = 0; i < rows.length; i++) {
        await txn.insert('playlist_tracks', {'playlist_id': id, 'track_id': rows[i].$1, 'item_id': rows[i].$2, 'position': i});
      }
    });
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
    if (added > 0) await syncHooks?.playlistEdited(id);
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
    final unique = withoutDuplicates(tracks).map((t) => t.id).toSet();
    final rows = await playlistRows(id);
    final seen = <String>{};
    final kept = [for (final r in rows) if (unique.contains(r.$1) && seen.add(r.$1)) r];
    final removed = rows.length - kept.length;
    if (removed > 0) await _rewritePlaylist(id, kept);
    return removed;
  }

  Future<void> removeFromPlaylist(int id, int index) async {
    final rows = await playlistRows(id);
    if (index < 0 || index >= rows.length) return;
    rows.removeAt(index);
    await _rewritePlaylist(id, rows);
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
    await syncHooks?.playlistEdited(id);
    _notify();
    return true;
  }

  /// Removes several rows (by position) from a playlist at once.
  Future<void> removeFromPlaylistAt(int id, List<int> indexes) async {
    final rows = await playlistRows(id);
    final drop = indexes.toSet();
    await _rewritePlaylist(id, [for (var i = 0; i < rows.length; i++) if (!drop.contains(i)) rows[i]]);
  }

  /// The playlist becomes exactly [trackIds], in order (sync).
  Future<void> replacePlaylistTracks(int id, List<String> trackIds) async {
    await db.transaction((txn) async {
      await txn.delete('playlist_tracks', where: 'playlist_id = ?', whereArgs: [id]);
      for (var i = 0; i < trackIds.length; i++) {
        await txn.insert('playlist_tracks', {'playlist_id': id, 'track_id': trackIds[i], 'position': i});
      }
    });
    _notify();
  }

  Future<void> reorderPlaylist(int id, int oldIndex, int newIndex) async {
    final rows = await playlistRows(id);
    final t = rows.removeAt(oldIndex);
    rows.insert(newIndex.clamp(0, rows.length), t);
    await _rewritePlaylist(id, rows);
  }

  /// A user change to the rows (entry ids kept), reported to [syncHooks].
  Future<void> _rewritePlaylist(int id, List<(String, String?)> rows) async {
    await db.transaction((txn) async {
      await txn.delete('playlist_tracks', where: 'playlist_id = ?', whereArgs: [id]);
      for (var i = 0; i < rows.length; i++) {
        await txn.insert('playlist_tracks', {'playlist_id': id, 'track_id': rows[i].$1, 'item_id': rows[i].$2, 'position': i});
      }
    });
    await syncHooks?.playlistEdited(id);
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

/// What playlist sync wants to hear from the library (see AppDatabase.syncHooks).
abstract class SyncHooks {
  Future<void> playlistEdited(int playlistId);
  Future<void> playlistDeleted(String? uid);
  Future<void> likesEdited();
  /// (title, artist) of the songs that left this device's library.
  Future<void> songsRemoved(List<(String, String)> songs);
  /// The user changed a song's details (編輯資訊, 找封面, 找原文歌名…).
  Future<void> trackEdited(Track before, Track after);
}
