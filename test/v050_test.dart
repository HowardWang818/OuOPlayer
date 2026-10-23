import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/db/database.dart';
import 'package:ouoplayer/services/audio_handler.dart';
import 'package:ouoplayer/services/download_service.dart';
import 'package:ouoplayer/services/ytdlp/ytdlp_downloader.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('shuffle reorders the real queue', () {
    final songs = List.generate(20, (i) => 'song$i');

    test('current song first, every song exactly once', () {
      final q = shuffledQueue(songs, 7, Random(1));
      expect(q.first, 'song7');
      expect(q.toSet(), songs.toSet());
      expect(q, hasLength(songs.length));
      expect(q, isNot(equals(songs)));
    });

    test('turning shuffle off restores the original order', () {
      final q = shuffledQueue(songs, 3, Random(2));
      expect(unshuffledQueue(songs, q), songs);
    });

    test('songs removed while shuffled stay removed; added ones go last', () {
      final q = shuffledQueue(songs, 0, Random(3))
        ..remove('song5')
        ..add('extra');
      final back = unshuffledQueue(songs, q);
      expect(back, isNot(contains('song5')));
      expect(back.last, 'extra');
      expect(back.first, 'song0');
    });
  });

  test('playlist download progress covers the whole list', () {
    expect(playlistProgress(50, null, null), 0.5);
    expect(playlistProgress(50, 1, 1), 0.5);
    expect(playlistProgress(0, 1, 10), 0.0);
    expect(playlistProgress(50, 3, 10), closeTo(0.25, 1e-9));
    expect(playlistProgress(100, 10, 10), 1.0);
  });

  group('v0.5.2 playlist downloads', () {
    test('progress lines carry song number and total', () {
      final e = YtDlpLineParser().parse('OUOPROG  50.0%|00:10|3|10') as YtDlpProgress;
      expect((e.item, e.itemCount), (3, 10));
      expect(playlistProgress(e.percent, e.item, e.itemCount), closeTo(0.25, 1e-9));
      final single = YtDlpLineParser().parse('OUOPROG  50.0%|00:10|NA|NA') as YtDlpProgress;
      expect(single.itemCount, isNull);
    });

    test('parses listing entries (titles may contain |)', () {
      final e = PlaylistEntry.parse('OUOENTRY 03|https://www.youtube.com/watch?v=abc|A | B')!;
      expect((e.index, e.url, e.title), (3, 'https://www.youtube.com/watch?v=abc', 'A | B'));
      expect(PlaylistEntry.parse('[youtube] something'), isNull);
    });

    test('only splits lists of distinct web pages', () {
      PlaylistEntry e(int i, String u) => PlaylistEntry(i, u, 't$i');
      expect(canSplitPlaylist([e(1, 'https://www.youtube.com/watch?v=a'), e(2, 'https://www.youtube.com/watch?v=b')]), isTrue);
      expect(canSplitPlaylist([e(1, 'https://www.youtube.com/watch?v=a')]), isFalse);
      expect(canSplitPlaylist([e(1, 'https://x/v'), e(2, 'https://x/v')]), isFalse);
      expect(canSplitPlaylist([e(1, 'https://archive.org/download/x/1.flac'), e(2, 'https://archive.org/download/x/2.flac')]), isFalse);
      expect(canSplitPlaylist([e(1, 'NA'), e(2, 'NA')]), isFalse);
    });
  });

  test('database upgrade to v2 keeps playlists and adds covers and folders', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute('CREATE TABLE playlists(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, created_at INTEGER)');
            await db.insert('playlists', {'name': '我的最愛', 'created_at': 1});
          },
        ));
    await AppDatabase.migrate(db, 1, 2);
    final rows = await db.query('playlists');
    expect(rows.single['name'], '我的最愛');
    expect(rows.single.containsKey('cover'), isTrue);
    expect(rows.single.containsKey('folder_id'), isTrue);
    await db.insert('playlist_folders', {'name': '日文歌', 'created_at': 2});
    expect(await db.query('playlist_folders'), hasLength(1));
    await db.close();
  });
}
