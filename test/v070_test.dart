import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/db/database.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/online/youtube_link.dart';
import 'package:ouoplayer/services/playlist_export.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('YouTube Music link prefers the official "- Topic" audio', () {
    Map<String, dynamic> item(String id, String channel) => {
          'id': {'kind': 'youtube#video', 'videoId': id},
          'snippet': {'title': id, 'channelTitle': channel},
        };
    final v = YouTubeLinkFinder.parse({
      'items': [item('mv', 'Ayase / YOASOBI'), item('cover', 'Someone'), item('audio', 'YOASOBI - Topic')],
    })!;
    expect(v.id, 'audio');
    expect(v.isOfficialAudio, isTrue);
    expect(v.url, 'https://music.youtube.com/watch?v=audio');
    final first = YouTubeLinkFinder.parse({'items': [item('mv', 'Ayase / YOASOBI')]})!;
    expect((first.id, first.isOfficialAudio), ('mv', false));
  });

  group('copy / export playlist', () {
    final tracks = [
      const Track(id: '1', uri: '/storage/emulated/0/Music/群青.mp3', title: '群青', artist: 'YOASOBI', album: 'THE BOOK', durationMs: 248000),
      const Track(id: '2', uri: 'https://example.com/a.mp3', title: 'Hello, "World"', artist: 'A'),
    ];
    final e = PlaylistExport('Liked', tracks);

    test('text', () {
      expect(e.text(), 'Liked（2 首）\n1. 群青 - YOASOBI\n2. Hello, "World" - A');
    });

    test('csv with BOM and quoting', () {
      final b = e.bytes(ExportFormat.csv);
      expect(b.take(3), [0xEF, 0xBB, 0xBF]);
      final lines = utf8.decode(b.sublist(3)).split('\r\n');
      expect(lines[0], '編號,歌名,歌手,專輯,長度');
      expect(lines[1], '1,群青,YOASOBI,THE BOOK,4:08');
      expect(lines[2], '2,"Hello, ""World""",A,未知專輯,');
    });

    test('m3u8', () {
      expect(e.m3u8().split('\n'), [
        '#EXTM3U',
        '#PLAYLIST:Liked',
        '#EXTINF:248,YOASOBI - 群青',
        '/storage/emulated/0/Music/群青.mp3',
        '#EXTINF:-1,A - Hello, "World"',
        'https://example.com/a.mp3',
      ]);
    });

    test('file names are safe', () {
      expect(PlaylistExport('a/b:c?', tracks).fileName(ExportFormat.m3u8), 'a_b_c_.m3u8');
      expect(PlaylistExport('  ', tracks).fileName(ExportFormat.text), '播放清單.txt');
    });
  });

  test('allowing duplicates adds the same song again; removing duplicates still cleans up', () async {
    sqfliteFfiInit();
    final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await raw.execute('CREATE TABLE tracks(id TEXT PRIMARY KEY, uri TEXT NOT NULL, title TEXT NOT NULL, artist TEXT, album TEXT, '
        'duration_ms INTEGER, art TEXT, source TEXT, track_no INTEGER, added_at INTEGER)');
    await raw.execute('CREATE TABLE playlist_tracks(playlist_id INTEGER, track_id TEXT, position INTEGER, item_id TEXT)');
    final db = AppDatabase.wrap(raw);
    Track t(String id) => Track(id: id, uri: id, title: id);
    await db.addToPlaylist(1, [t('a'), t('b')]);
    expect(await db.addToPlaylist(1, [t('a')]), 0);
    expect(await db.addToPlaylist(1, [t('a')], allowDuplicates: true), 1);
    expect((await db.playlistTracks(1)).map((x) => x.id), ['a', 'b', 'a']);
    expect(await db.removePlaylistDuplicates(1), 1);
    expect((await db.playlistTracks(1)).map((x) => x.id), ['a', 'b']);
    await raw.close();
  });
}
