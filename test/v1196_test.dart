// 1.19.6: two devices used normally, upgraded and restarted, and a user
// action landing while sync is applying (it used to be lost).
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/db/database.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/sync/drive_client.dart';
import 'package:ouoplayer/services/sync2/engine.dart';
import 'package:ouoplayer/services/sync2/sync_log.dart';

import 'sync2_test.dart' show FakeDrive;
import 'v0120_test.dart' show openDb;

var _clock = 5000000;

class Dev {
  Dev(this.name, this.db, this.dir, this.drive);
  final String name;
  final AppDatabase db;
  final Directory dir;
  final DriveStore drive;
  late SyncEngine engine;
  final lyrics = <String, ({String lrc, bool manual, int at})>{};

  /// Runs inside sync's own writes (setLyrics is called while it applies).
  Future<void> Function()? duringApply;
  Future<void>? userAction;

  /// A new engine on the same database: the app restarted or upgraded.
  void start() {
    engine = SyncEngine(
      db: db,
      drive: CachedDrive(drive),
      deviceId: () async => name,
      deviceName: name,
      importFile: (path) async {
        final t = Track(id: path, uri: path, title: 'x', artist: 'A', durationMs: 200000, source: TrackSource.download, addedAt: 1);
        await db.upsertTracks([t]);
        return t;
      },
      storeArt: (bytes, mime) async => (File('${dir.path}/art_${bytes.length}.jpg')..writeAsBytesSync(bytes)).path,
      lyricsOf: (t) async => lyrics[t.id],
      setLyrics: (t, lrc, manual) async {
        lyrics[t.id] = (lrc: lrc, manual: manual, at: _clock += 1000);
        // The user's tap: its own task (outside sync's zone), not awaited here.
        final f = duringApply;
        duringApply = null;
        if (f != null) {
          userAction = Zone.root.run(f);
          // Sync is still applying while the tap's work runs.
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      },
      downloadDir: () => '${dir.path}/dl',
      clock: () => _clock += 1000,
    );
  }

  static Future<Dev> make(String name, DriveStore drive) async {
    final d = Dev(name, await openDb(), await Directory.systemTemp.createTemp('sim_$name'), drive);
    d.start();
    return d;
  }

  Future<Track> song(String title) async {
    final f = File('${dir.path}/$title.mp3')..writeAsStringSync('audio $title');
    final t = Track(id: f.path, uri: f.path, title: title, artist: 'A', durationMs: 200000, source: TrackSource.local, addedAt: 1);
    await db.upsertTracks([t]);
    return t;
  }

  Future<void> sync() => engine.sync(confirmDelete: (_) async => true);

  Future<int?> idOf(String name) async => (await db.db.query('playlists', where: 'name = ?', whereArgs: [name])).firstOrNull?['id'] as int?;

  Future<List<String>> titles(String list) async {
    final id = await idOf(list);
    return id == null ? const [] : [for (final t in await db.playlistTracks(id)) t.title];
  }

  Future<void> remove(String list, String title) async {
    final id = (await idOf(list))!;
    final tracks = await db.playlistTracks(id);
    await db.removeFromPlaylistAt(id, [tracks.indexWhere((t) => t.title == title)]);
  }
}

Future<void> both(Dev a, Dev b, [int rounds = 2]) async {
  for (var i = 0; i < rounds; i++) {
    await a.sync();
    await b.sync();
  }
}

void main() {
  late FakeDrive drive;
  late Dev phone, pc;
  setUp(() async {
    drive = FakeDrive();
    phone = await Dev.make('phone', drive);
    pc = await Dev.make('pc', drive);
    // Both have the same three songs, the playlist starts on the phone.
    for (final d in [phone, pc]) {
      for (final s in ['群青', '夜に駆ける', 'アイドル']) {
        await d.song(s);
      }
    }
    final id = await phone.db.createPlaylist('通勤');
    await phone.db.addToPlaylist(id, [for (final t in await phone.db.tracks()) t]);
    await phone.engine.enable(id);
    await both(phone, pc);
  });

  test('normal use with upgrades and restarts: a removed song stays removed', () async {
    expect(await pc.titles('通勤'), hasLength(3));
    await phone.remove('通勤', '群青');
    await both(phone, pc);
    expect(await pc.titles('通勤'), isNot(contains('群青')));
    // Both upgraded (new engines on the same data), several syncs, restarts.
    for (var i = 0; i < 5; i++) {
      phone.start();
      pc.start();
      await both(phone, pc);
    }
    expect(await phone.titles('通勤'), isNot(contains('群青')));
    expect(await pc.titles('通勤'), isNot(contains('群青')));
  });

  test('normal use with upgrades: a rename stays', () async {
    final t = (await phone.db.tracks()).firstWhere((t) => t.title == 'アイドル');
    await phone.db.updateTrackInfo(Track(id: t.id, uri: t.uri, title: 'アイドル (原名)', artist: t.artist, album: t.album, durationMs: t.durationMs, source: t.source, addedAt: t.addedAt));
    await both(phone, pc);
    for (var i = 0; i < 5; i++) {
      phone.start();
      pc.start();
      await both(phone, pc);
    }
    expect((await phone.db.tracks()).map((t) => t.title), contains('アイドル (原名)'));
    expect((await pc.db.tracks()).map((t) => t.title), contains('アイドル (原名)'));
  });

  test('a removal made while sync is applying sticks and reaches the other device', () async {
    // The pc has lyrics for a song: the phone's next sync adopts them, and
    // the user removes 群青 right at that moment.
    final pcSong = (await pc.db.tracks()).firstWhere((t) => t.title == '夜に駆ける');
    pc.lyrics[pcSong.id] = (lrc: '[00:01]x', manual: true, at: _clock += 1000);
    phone.duringApply = () => phone.remove('通勤', '群青');
    await phone.sync();
    await phone.userAction;
    final rightAfter = await phone.titles('通勤');
    expect(rightAfter, isNotEmpty);
    await both(phone, pc, 3);
    expect(await phone.titles('通勤'), isNot(contains('群青')), reason: 'the removal sticks here');
    expect(await pc.titles('通勤'), isNot(contains('群青')), reason: 'and reaches the other device');
    // 同步紀錄 on the pc says where it went.
    final log = await SyncLog.read(pc.db);
    expect(log.map((e) => e.text), contains('「通勤」移除「群青」'));
  });

  test('a rename made while sync is applying is kept and sent', () async {
    final pcSong = (await pc.db.tracks()).firstWhere((t) => t.title == '夜に駆ける');
    pc.lyrics[pcSong.id] = (lrc: '[00:01]x', manual: true, at: _clock += 1000);
    final t = (await phone.db.tracks()).firstWhere((t) => t.title == 'アイドル');
    phone.duringApply = () => phone.db.updateTrackInfo(Track(
        id: t.id, uri: t.uri, title: 'アイドル (原名)', artist: t.artist, album: t.album, durationMs: t.durationMs, source: t.source, addedAt: t.addedAt));
    await phone.sync();
    await phone.userAction;
    await both(phone, pc, 3);
    expect((await phone.db.tracks()).map((t) => t.title), contains('アイドル (原名)'));
    expect((await pc.db.tracks()).map((t) => t.title), contains('アイドル (原名)'), reason: 'the rename should reach the pc');
  });

  test('the log keeps the newest 100', () async {
    final db = await openDb();
    await SyncLog.add(db, [for (var i = 0; i < 120; i++) SyncLogEntry(DateTime(2026, 11, 12, 0, i), '#$i')]);
    final log = await SyncLog.read(db);
    expect(log, hasLength(SyncLog.keep));
    expect(log.first.text, '#119');
  });
}
