import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/db/database.dart';
import 'package:ouoplayer/services/online/itunes.dart';
import 'package:ouoplayer/services/storage_usage.dart';
import 'package:ouoplayer/services/ytdlp_auto_update.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('podcast search results keep only shows with an RSS feed', () {
    const body = '{"resultCount": 2, "results": ['
        '{"wrapperType": "track", "kind": "podcast", "collectionName": "股癌 Gooaye", "artistName": "謝孟恭", '
        '"feedUrl": "https://feeds.example.com/gooaye.xml", "artworkUrl600": "https://img/600.jpg", '
        '"artworkUrl100": "https://img/100.jpg", "primaryGenreName": "投資", "trackCount": 500},'
        '{"wrapperType": "track", "kind": "podcast", "collectionName": "Apple only", "artistName": "x"}]}';
    final list = ITunesSearch.parsePodcasts(body);
    expect(list, hasLength(1));
    final p = list.single;
    expect((p.title, p.author, p.genre, p.episodes), ('股癌 Gooaye', '謝孟恭', '投資', 500));
    expect(p.artwork, 'https://img/600.jpg');
    final pod = p.toPodcast();
    expect((pod.feedUrl, pod.title, pod.image), ('https://feeds.example.com/gooaye.xml', '股癌 Gooaye', 'https://img/600.jpg'));
  });

  group('storage', () {
    test('sizes read nicely', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
      expect(formatBytes(300 * 1024 * 1024), '300 MB');
    });

    test('a cache folder is measured and emptied, the folder stays', () async {
      final dir = await Directory.systemTemp.createTemp('ouo_cache');
      await File('${dir.path}/a.json').writeAsBytes(List.filled(1000, 1));
      await Directory('${dir.path}/job1').create();
      await File('${dir.path}/job1/part.webm').writeAsBytes(List.filled(500, 1));
      expect(await folderSize(dir), 1500);
      expect(await clearFolder(dir), 1500);
      expect(await folderSize(dir), 0);
      expect(await dir.exists(), isTrue);
      await dir.delete(recursive: true);
      expect(await folderSize(dir), 0);
    });
  });

  test('yt-dlp updates once a week', () {
    final now = DateTime(2026, 10, 24);
    expect(ytDlpUpdateDue(null, now), isTrue);
    expect(ytDlpUpdateDue(now.subtract(const Duration(days: 6)), now), isFalse);
    expect(ytDlpUpdateDue(now.subtract(const Duration(days: 7)), now), isTrue);
  });

  test('upgrading to v5 adds the indexes', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath, options: OpenDatabaseOptions(singleInstance: false));
    await db.execute('CREATE TABLE tracks(id TEXT PRIMARY KEY, uri TEXT, title TEXT, source TEXT, added_at INTEGER)');
    await db.execute('CREATE TABLE playlist_tracks(playlist_id INTEGER, track_id TEXT, position INTEGER)');
    await db.execute('CREATE TABLE history(track_id TEXT, played_at INTEGER)');
    await db.execute('CREATE TABLE plays(track_id TEXT PRIMARY KEY, count INTEGER NOT NULL, last_played INTEGER)');
    await AppDatabase.migrate(db, 4, 5);
    final names = (await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'index'")).map((r) => r['name']).toSet();
    expect(names, containsAll(['idx_tracks_source', 'idx_tracks_added', 'idx_playlist_tracks_list', 'idx_plays_count']));
    // Running it twice is harmless.
    await AppDatabase.migrate(db, 4, 5);
    await db.close();
  });
}
