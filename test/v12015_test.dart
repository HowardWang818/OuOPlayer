// 1.20.15: songs moved to another folder by hand go back to the songs they
// were; the downloads can move with a new download folder; 下載缺少的歌 on
// YouTube / SoundCloud takes a result whose title and length fit.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/folder_ops.dart';
import 'package:ouoplayer/services/library_scanner.dart';
import 'package:ouoplayer/services/moved_files.dart';
import 'package:ouoplayer/services/online/online_search.dart';
import 'package:ouoplayer/services/online/ytmusic.dart';

import 'v0120_test.dart' show openDb;

late Directory _dir;

YtMusicSong _r(String title, int? ms) => YtMusicSong(videoId: title, title: title, artist: 'someone', durationMs: ms, link: 'https://x/$title');

Track _t(String path, {String title = 'Tone', int? ms = 1000, String source = TrackSource.download}) =>
    Track(id: path, uri: path, title: title, artist: 'Test', album: 'x', durationMs: ms, source: source, addedAt: 1);

File _file(String folder, String name) {
  final d = Directory('${_dir.path}/$folder')..createSync(recursive: true);
  return File('test/fixtures/tone.mp3').copySync('${d.path}/$name');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    _dir = Directory.systemTemp.createTempSync('v12015');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (call) async => _dir.path);
  });
  tearDown(() {
    try {
      _dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('下載缺少的歌 on YouTube / SoundCloud', () {
    test('title held and length within 3 s: sure', () {
      final r = [_r('千本桜 (cover)', 245000), _r('Ado『千本桜』MV', 246000), _r('千本桜', 300000)];
      expect(sureByTitle('千本桜', 245500, r)?.title, 'Ado『千本桜』MV');
    });
    test('wrong length, another take, or no length known: not sure', () {
      expect(sureByTitle('千本桜', 245000, [_r('千本桜', 260000)]), isNull);
      expect(sureByTitle('千本桜', 245000, [_r('千本桜 Live', 245000)]), isNull);
      expect(sureByTitle('千本桜', null, [_r('千本桜', 245000)]), isNull);
      expect(sureByTitle('千本桜', 245000, [_r('千本桜', null)]), isNull);
    });
  });

  group('songs moved by hand', () {
    test('the old song moves to the new file; the new entry goes; counts add up', () async {
      final db = await openDb();
      final oldPath = '${_dir.path}/old/Tone.mp3';
      final now = _file('new', 'Tone.mp3');
      await db.upsertTracks([_t(oldPath), _t(now.path, source: TrackSource.local)]);
      final list = await db.createPlaylist('通勤');
      await db.addToPlaylist(list, [_t(oldPath)]);
      await db.setFavorite(_t(oldPath), true);
      await db.db.insert('plays', {'track_id': oldPath, 'count': 3, 'last_played': 10});
      await db.db.insert('plays', {'track_id': now.path, 'count': 1, 'last_played': 20});
      expect(await MovedFiles.repairOnce(db), 1);
      final all = await db.tracks();
      expect(all.map((t) => t.id), [now.path]);
      expect(all.single.source, TrackSource.download);
      expect((await db.playlistRows(list)).map((r) => r.$1), [now.path]);
      expect((await db.favorites()).map((t) => t.id), [now.path]);
      final plays = await db.db.query('plays');
      expect(plays.single['count'], 4);
      expect(plays.single['last_played'], 20);
      expect(await MovedFiles.repairOnce(db), 0, reason: 'once');
    });

    test('another length, or two songs with the name: left alone', () async {
      final db = await openDb();
      final now = _file('new', 'Tone.mp3');
      expect(MovedFiles.pairs([_t('${_dir.path}/old/Tone.mp3', ms: 90000)], [_t(now.path, source: TrackSource.local)]), isEmpty);
      expect(
          MovedFiles.pairs([_t('${_dir.path}/a/Tone.mp3'), _t('${_dir.path}/b/Tone.mp3')], [_t(now.path, source: TrackSource.local)]),
          isEmpty);
      expect(MovedFiles.pairs([_t('${_dir.path}/a/Tone.mp3')], [_t(now.path, source: TrackSource.local)]).length, 1);
      await db.mergeMovedTracks({'${_dir.path}/nothing.mp3': now.path});
      expect(await db.tracks(), isEmpty, reason: 'nothing there to move: nothing deleted either');
    });

    test('a scan of the new folder adds no second song', () async {
      final db = await openDb();
      final oldPath = '${_dir.path}/old/Tone.mp3';
      final list = await db.createPlaylist('通勤');
      await db.upsertTracks([_t(oldPath, title: 'Tone', ms: null)]);
      await db.addToPlaylist(list, [_t(oldPath)]);
      _file('new', 'Tone.mp3');
      await LibraryScanner(db).scan(['${_dir.path}/new']);
      final all = await db.tracks();
      expect(all.length, 1);
      expect(all.single.id, endsWith('Tone.mp3'));
      expect(File(all.single.uri).existsSync(), isTrue);
      expect((await db.playlistRows(list)).single.$1, all.single.id);
    });
  });

  test('a new download folder: the downloads come along', () async {
    final db = await openDb();
    final a = _file('dl', 'a.mp3');
    Directory('${_dir.path}/dl/sub').createSync();
    final b = File(a.path).copySync('${_dir.path}/dl/sub/b.mp3');
    await db.upsertTracks([_t(a.path, title: 'a'), _t(b.path, title: 'b')]);
    final list = await db.createPlaylist('通勤');
    await db.addToPlaylist(list, [_t(a.path)]);
    final r = await FolderOps(db, mover: (moves) async {
      for (final e in moves.entries) {
        File(e.key).renameSync(e.value);
      }
      return true;
    }).moveBetween(await db.tracks(), '${_dir.path}/dl', '${_dir.path}/music');
    expect(r.moved.length, 2);
    expect(r.failed, 0);
    final ids = (await db.tracks()).map((t) => t.id).toSet();
    expect(ids.every((i) => i.contains('music') && File(i).existsSync()), isTrue);
    expect(ids.any((i) => i.endsWith('music${Platform.pathSeparator}sub${Platform.pathSeparator}b.mp3')), isTrue);
    expect((await db.playlistRows(list)).single.$1, contains('music'));
  });
}
