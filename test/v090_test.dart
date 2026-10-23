import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/db/database.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/backup.dart';
import 'package:ouoplayer/services/library_scanner.dart';
import 'package:ouoplayer/services/playlist_import.dart';
import 'package:ouoplayer/services/tag_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A fresh database with the app's full schema.
Future<AppDatabase> openTestDb() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath, options: OpenDatabaseOptions(singleInstance: false));
  await db.execute('CREATE TABLE tracks(id TEXT PRIMARY KEY, uri TEXT NOT NULL, title TEXT NOT NULL, artist TEXT, album TEXT, '
      'duration_ms INTEGER, art TEXT, source TEXT, track_no INTEGER, added_at INTEGER)');
  await db.execute('CREATE TABLE playlists(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, created_at INTEGER)');
  await db.execute('CREATE TABLE playlist_tracks(playlist_id INTEGER, track_id TEXT, position INTEGER)');
  await db.execute('CREATE TABLE favorites(track_id TEXT PRIMARY KEY, added_at INTEGER)');
  await db.execute('CREATE TABLE history(track_id TEXT, played_at INTEGER)');
  await db.execute('CREATE TABLE podcasts(feed_url TEXT PRIMARY KEY, title TEXT, author TEXT, image TEXT, added_at INTEGER)');
  await db.execute('CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT)');
  await AppDatabase.migrate(db, 1, AppDatabase.schemaVersion);
  return AppDatabase.wrap(db);
}

Track song(String id, {String? title, String artist = 'A', int added = 0}) =>
    Track(id: id, uri: id, title: title ?? id, artist: artist, source: TrackSource.download, addedAt: added);

void main() {
  test('upgrading to v4 keeps play counts from the history', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath, options: OpenDatabaseOptions(singleInstance: false));
    await db.execute('CREATE TABLE history(track_id TEXT, played_at INTEGER)');
    for (final (id, at) in [('a', 1), ('a', 5), ('b', 3)]) {
      await db.insert('history', {'track_id': id, 'played_at': at});
    }
    await db.execute('CREATE TABLE download_history(source TEXT PRIMARY KEY, path TEXT NOT NULL, created_at INTEGER)');
    await AppDatabase.migrate(db, 3, 4);
    final plays = await db.query('plays', orderBy: 'track_id');
    expect(plays.map((r) => (r['track_id'], r['count'], r['last_played'])), [('a', 2, 5), ('b', 1, 3)]);
    await db.close();
  });

  test('smart playlists follow play counts', () async {
    final db = await openTestDb();
    for (final t in [song('a', added: 1), song('b', added: 2), song('c', added: 3)]) {
      await db.db.insert('tracks', t.toMap());
    }
    await db.addHistory(song('a'));
    await db.addHistory(song('a'));
    await db.addHistory(song('b'));
    expect((await db.smartTracks(SmartList.mostPlayed)).map((t) => t.id), ['a', 'b']);
    expect((await db.smartTracks(SmartList.recentlyAdded)).map((t) => t.id), ['c', 'b', 'a']);
    expect((await db.smartTracks(SmartList.neverPlayed)).map((t) => t.id), ['c']);
    expect(await db.smartTracks(SmartList.notPlayedLately), isEmpty);
    await db.db.update('plays', {'last_played': 0}, where: 'track_id = ?', whereArgs: ['b']);
    expect((await db.smartTracks(SmartList.notPlayedLately)).map((t) => t.id), ['b']);
    expect(await db.playCounts(), {'a': 2, 'b': 1});
  });

  test('podcast progress is remembered and can be cleared', () async {
    final db = await openTestDb();
    await db.savePodcastProgress('https://x/ep1.mp3', const Duration(minutes: 12), const Duration(minutes: 40));
    await db.savePodcastProgress('https://x/ep2.mp3', Duration.zero, null, finished: true);
    final p = await db.podcastProgress();
    expect(p['https://x/ep1.mp3']!.position, const Duration(minutes: 12));
    expect(p['https://x/ep1.mp3']!.finished, isFalse);
    expect(p['https://x/ep2.mp3']!.finished, isTrue);
    await db.clearPodcastProgress('https://x/ep1.mp3');
    expect((await db.podcastProgress()).keys, ['https://x/ep2.mp3']);
  });

  group('M3U import', () {
    test('reads titles, relative paths, file URIs and URLs', () {
      final m = M3uPlaylist.parse(
          '\uFEFF#EXTM3U\n#PLAYLIST:通勤\n#EXTINF:248,YOASOBI - 群青\nsongs/群青.mp3\n'
          '#EXTINF:-1,Radio\nhttps://example.com/live.mp3\nfile:///storage/emulated/0/Music/a%20b.mp3\n',
          baseDir: '/storage/emulated/0/Music');
      expect(m.name, '通勤');
      expect(m.entries.map((e) => e.location),
          ['/storage/emulated/0/Music/songs/群青.mp3', 'https://example.com/live.mp3', '/storage/emulated/0/Music/a b.mp3']);
      expect((m.entries[0].title, m.entries[0].artist, m.entries[0].durationSec), ('群青', 'YOASOBI', 248));
      expect(m.entries[1].isUrl, isTrue);
      expect(m.entries[1].durationSec, isNull);
    });

    test('songs are found by path, file name, or title and artist', () {
      final lib = LibraryMatcher([
        const Track(id: '/m/群青.mp3', uri: '/m/群青.mp3', title: '群青', artist: 'YOASOBI'),
        const Track(id: '/m/x/propose.m4a', uri: '/m/x/propose.m4a', title: 'propose', artist: 'natori'),
      ]);
      expect(lib.find('/m/群青.mp3')?.id, '/m/群青.mp3');
      expect(lib.find(r'D:\Music\propose.m4a')?.id, '/m/x/propose.m4a');
      expect(lib.find('/other/gunjou.flac', title: '群青', artist: 'YOASOBI')?.id, '/m/群青.mp3');
      expect(lib.find('/other/nothing.mp3', title: 'propose', artist: '9Lana'), isNull);
    });
  });

  test('a backup restores into another library by title and artist', () async {
    final src = await openTestDb();
    await src.db.insert('tracks', song('/old/群青.mp3', title: '群青', artist: 'YOASOBI').toMap());
    await src.db.insert('tracks', song('/old/gone.mp3', title: 'gone').toMap());
    final folder = await src.db.insert('playlist_folders', {'name': '日文', 'created_at': 1});
    final pl = await src.createPlaylist('Liked');
    await src.db.update('playlists', {'folder_id': folder}, where: 'id = ?', whereArgs: [pl]);
    await src.addToPlaylist(pl, [song('/old/群青.mp3', title: '群青', artist: 'YOASOBI'), song('/old/gone.mp3', title: 'gone')]);
    await src.db.insert('favorites', {'track_id': '/old/群青.mp3', 'added_at': 7});
    await src.addHistory(song('/old/群青.mp3', title: '群青', artist: 'YOASOBI'));
    await src.setSetting('theme', 'light');
    await src.setSetting('youtube_api_key', 'secret');
    final backup = jsonDecode(jsonEncode(await buildBackup(src))) as Map<String, Object?>;
    expect((backup['settings'] as Map).containsKey('youtube_api_key'), isFalse);

    final dst = await openTestDb();
    await dst.db.insert('tracks', song('/new/Music/群青.mp3', title: '群青', artist: 'YOASOBI').toMap());
    await dst.createPlaylist('會被取代');
    final covers = await Directory.systemTemp.createTemp('ouo_covers');
    final report = await restoreBackup(dst, LibraryScanner(dst), backup, coverDir: covers);
    expect(report.playlists, 1);
    expect(report.songs, 1);
    expect(report.missing, ['gone - A']);
    final lists = await dst.playlists();
    expect(lists.map((l) => (l.name, l.count)), [('Liked', 1)]);
    expect((await dst.playlistTracks(lists.single.id)).single.id, '/new/Music/群青.mp3');
    expect(await dst.favoriteIds(), {'/new/Music/群青.mp3'});
    expect(await dst.playCounts(), {'/new/Music/群青.mp3': 1});
    expect((await dst.allSettings())['theme'], 'light');
    expect((await dst.db.query('playlist_folders')).single['name'], '日文');
    await covers.delete(recursive: true);
  });

  test('tags are written only for formats that support it', () {
    expect(canWriteTags('/m/a.mp3'), isTrue);
    expect(canWriteTags('/m/a.M4A'), isTrue);
    expect(canWriteTags('/m/a.flac'), isTrue);
    expect(canWriteTags('/m/a.opus'), isFalse);
    expect(canWriteTags('/m/a.webm'), isFalse);
  });
}
