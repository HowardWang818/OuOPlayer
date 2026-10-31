import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/db/database.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/download_match.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('YouTube links share one history key', () {
    const key = 'youtube:abc123';
    expect(sourceKey('https://www.youtube.com/watch?v=abc123&list=PL1&index=3'), key);
    expect(sourceKey('https://youtu.be/abc123?si=x'), key);
    expect(sourceKey('https://music.youtube.com/watch?v=abc123'), key);
    expect(sourceKey('https://www.youtube.com/shorts/abc123'), key);
    expect(sourceKey('https://example.com/a.mp3'), 'https://example.com/a.mp3');
  });

  test('recognises whole-playlist links', () {
    expect(isPlaylistUrl('https://www.youtube.com/playlist?list=PL123'), isTrue);
    expect(isPlaylistUrl('https://music.youtube.com/playlist?list=OLAK5uy'), isTrue);
    expect(isPlaylistUrl('https://youtube.com/watch?list=PL123'), isTrue);
    // A video that carries a list: the 下載整個播放清單 choice decides.
    expect(isPlaylistUrl('https://www.youtube.com/watch?v=abc&list=PL123'), isFalse);
    expect(isPlaylistUrl('https://www.youtube.com/watch?v=abc'), isFalse);
    expect(isPlaylistUrl('https://soundcloud.com/artist/sets/best-of'), isTrue);
    expect(isPlaylistUrl('https://example.com/song.mp3'), isFalse);
  });

  test('titles match yt-dlp file names despite swapped punctuation', () {
    expect(normalizeName('夜に駆ける / YOASOBI?'), normalizeName('夜に駆ける ⧸ YOASOBI？'));
    expect(normalizeName('A-B_C'), 'abc');
  });

  test('finds an existing file in any format, including cut-off long names', () async {
    final dir = await Directory.systemTemp.createTemp('ouo_match');
    try {
      await File(p.join(dir.path, '群青 ⧸ YOASOBI.mp3')).writeAsString('x');
      final long = 'A very long live performance title that goes on and on' * 3;
      await File(p.join(dir.path, '${long.substring(0, 120)}.m4a')).writeAsString('x');
      await File(p.join(dir.path, 'cover.jpg')).writeAsString('x');
      final files = await ExistingFiles.scan(dir.path);
      expect(files.match('群青 / YOASOBI'), endsWith('.mp3'));
      expect(files.match(long), endsWith('.m4a'));
      expect(files.match('cover'), isNull);
      expect(files.match('群青'), isNull);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('database upgrade to v3 adds the download history', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute('CREATE TABLE playlists(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, created_at INTEGER)');
          },
        ));
    await AppDatabase.migrate(db, 1, 3);
    await db.insert('download_history', {'source': 'youtube:abc', 'path': '/x.m4a', 'created_at': 1});
    expect((await db.query('download_history')).single['path'], '/x.m4a');
    await db.close();
  });

  group('v0.6.3 playlists keep each song once', () {
    Track t(String id) => Track(id: id, uri: id, title: id);

    Future<AppDatabase> openDb() async {
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute('CREATE TABLE tracks(id TEXT PRIMARY KEY, uri TEXT NOT NULL, title TEXT NOT NULL, artist TEXT, album TEXT, '
          'duration_ms INTEGER, art TEXT, source TEXT, track_no INTEGER, added_at INTEGER)');
      await db.execute('CREATE TABLE playlist_tracks(playlist_id INTEGER, track_id TEXT, position INTEGER, item_id TEXT)');
      return AppDatabase.wrap(db);
    }

    test('adding a song that is already there does nothing', () async {
      final db = await openDb();
      expect(await db.addToPlaylist(1, [t('a'), t('b'), t('a')]), 2);
      expect(await db.addToPlaylist(1, [t('b'), t('c')]), 1);
      expect(await db.addToPlaylistAt(1, t('a'), 10), isFalse);
      expect(await db.addToPlaylistAt(1, t('d'), 10), isTrue);
      expect((await db.playlistTracks(1)).map((x) => x.id), ['a', 'b', 'c', 'd']);
      await db.db.close();
    });

    test('removing duplicates keeps the first of each, in order', () async {
      final db = await openDb();
      var pos = 0;
      for (final id in ['a', 'b', 'a', 'c', 'b', 'a']) {
        await db.db.insert('tracks', t(id).toMap(), conflictAlgorithm: ConflictAlgorithm.ignore);
        await db.db.insert('playlist_tracks', {'playlist_id': 1, 'track_id': id, 'position': pos++});
      }
      expect(await db.removePlaylistDuplicates(1), 3);
      expect((await db.playlistTracks(1)).map((x) => x.id), ['a', 'b', 'c']);
      expect(await db.removePlaylistDuplicates(1), 0);
      await db.db.close();
    });
  });
}
