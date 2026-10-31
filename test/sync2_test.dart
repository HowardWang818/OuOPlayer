import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/db/database.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/sync/drive_client.dart';
import 'package:ouoplayer/services/sync2/engine.dart';
import 'package:ouoplayer/services/sync2/merge.dart';
import 'package:ouoplayer/services/sync2/now_playing.dart';

import 'v0120_test.dart' show openDb;

/// Google Drive's app folder, in memory.
class FakeDrive implements DriveStore {
  final files = <String, (String name, Uint8List bytes, DateTime modified)>{};
  var _n = 0;
  DateTime _now() => DateTime.now();

  @override
  Future<List<DriveFile>> list() async => [for (final e in files.entries) DriveFile(e.key, e.value.$1, e.value.$3)];
  @override
  Future<Uint8List> download(String id) async => files[id]!.$2;
  @override
  Future<String> upload(String name, List<int> bytes, {String? id, String mime = ''}) async {
    final key = id ?? 'f${_n++}';
    files[key] = (name, Uint8List.fromList(bytes), _now());
    return key;
  }

  @override
  Future<String> uploadFile(String name, File file, {String mime = '', void Function(int, int)? onProgress, CancelToken? cancel}) async =>
      upload(name, await file.readAsBytes());
  @override
  Future<void> downloadTo(String id, String path, {void Function(int, int)? onProgress, CancelToken? cancel}) async =>
      File(path).writeAsBytes(files[id]!.$2);
  @override
  Future<void> delete(String id) async => files.remove(id);

  int get songs => files.values.where((f) => f.$1.startsWith('v2-song-')).length;
}

/// A device: its own library (database + music folder) and sync engine.
class Device {
  Device._(this.name, this.db, this.dir, this.engine, this.lyrics);
  final String name;

  /// Lyrics kept here: song id → (lrc, picked by hand, when).
  final Map<String, ({String lrc, bool manual, int at})> lyrics;
  final AppDatabase db;
  final Directory dir;
  final SyncEngine engine;
  static var _clock = 1000000;

  static Future<Device> make(String name, FakeDrive drive) async {
    final db = await openDb();
    final dir = await Directory.systemTemp.createTemp('ouo_$name');
    late SyncEngine engine;
    final lyrics = <String, ({String lrc, bool manual, int at})>{};
    engine = SyncEngine(
      db: db,
      drive: drive,
      deviceId: () async => name,
      deviceName: name,
      importFile: (path) async {
        final t = Track(id: path, uri: path, title: 'tagged', artist: 'x', durationMs: 200000, source: TrackSource.download, addedAt: 1);
        await db.upsertTracks([t]);
        return t;
      },
      storeArt: (bytes, mime) async {
        final f = File('${dir.path}/art_${bytes.length}.jpg')..writeAsBytesSync(bytes);
        return f.path;
      },
      lyricsOf: (t) async => lyrics[t.id],
      setLyrics: (t, lrc, manual) async => lyrics[t.id] = (lrc: lrc, manual: manual, at: _clock += 1000),
      downloadDir: () => '${dir.path}/dl',
      clock: () => _clock += 1000,
    );
    return Device._(name, db, dir, engine, lyrics);
  }

  /// A song file on this device.
  Future<Track> song(String title) async {
    final f = File('${dir.path}/$title.mp3')..writeAsStringSync('audio of $title');
    final t = Track(id: f.path, uri: f.path, title: title, artist: 'A', durationMs: 200000, source: TrackSource.local, addedAt: 1);
    await db.upsertTracks([t]);
    return t;
  }

  Future<int> playlist(String name, List<Track> songs, {bool sync = true}) async {
    final id = await db.createPlaylist(name);
    await db.addToPlaylist(id, songs, allowDuplicates: true);
    if (sync) await engine.enable(id);
    return id;
  }

  Future<SyncResult> sync({bool deleteOk = true}) => engine.sync(confirmDelete: (_) async => deleteOk);
  Future<void> transfer() => engine.runTransfers(relayCap: 1 << 30);

  Future<int?> idOf(String name) async =>
      (await db.db.query('playlists', where: 'name = ?', whereArgs: [name])).firstOrNull?['id'] as int?;

  /// Titles in a playlist ('~' marks a greyed song this device doesn't have).
  Future<List<String>> titles(String name) async {
    final id = await idOf(name);
    if (id == null) return const [];
    return [for (final t in await db.playlistTracks(id)) t.source == TrackSource.missing ? '~${t.title}' : t.title];
  }
}

void main() {
  late FakeDrive drive;
  late Device phone, pc;
  setUp(() async {
    drive = FakeDrive();
    phone = await Device.make('phone', drive);
    pc = await Device.make('pc', drive);
  });

  /// Both sync until nothing changes (songs included).
  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      for (final d in [phone, pc]) {
        await d.sync();
        await d.transfer();
      }
    }
  }

  test('a synced playlist reaches the other device, and its missing songs come over the relay', () async {
    final a = await phone.song('a'), b = await phone.song('b');
    await pc.song('a');
    await phone.playlist('Drive', [a, b]);
    await settle();
    expect(await pc.titles('Drive'), ['a', 'b']);
    // Delivered: nothing left on the relay, and no unfinished file in the
    // download folder (Android allows only audio files there).
    expect(drive.songs, 0);
    expect(Directory('${pc.dir.path}/dl').listSync().map((f) => f.path).where((n) => n.endsWith('.part')), isEmpty);
  });

  test('songs going away on one device are not playlist changes', () async {
    final a = await phone.song('a'), b = await phone.song('b');
    await phone.playlist('Drive', [a, b]);
    await settle();
    // The phone hides a song from its library (or its folder is removed).
    await phone.db.deleteTracks([a.id]);
    await settle();
    expect(await phone.titles('Drive'), ['~a', 'b']);
    expect(await pc.titles('Drive'), ['a', 'b']);
  });

  test('removing, adding, moving and renaming go both ways', () async {
    final a = await phone.song('a'), b = await phone.song('b'), c = await phone.song('c');
    final id = await phone.playlist('Drive', [a, b, c]);
    await settle();
    await phone.db.removeFromPlaylist(id, 0); // b c
    final pcId = (await pc.idOf('Drive'))!;
    await pc.db.reorderPlaylist(pcId, 2, 0); // c a b on the computer
    await pc.db.renamePlaylist(pcId, 'Car');
    await settle();
    expect(await phone.titles('Car'), ['c', 'b']);
    expect(await pc.titles('Car'), ['c', 'b']);
  });

  test('the same playlist made on both devices becomes one on the first sync', () async {
    final a = await phone.song('a'), b = await phone.song('b');
    final pcA = await pc.song('a'), c = await pc.song('c');
    await phone.playlist('Drive', [a, b]);
    await pc.playlist('Drive', [pcA, c]);
    await settle();
    final p = await phone.titles('Drive'), q = await pc.titles('Drive');
    expect(p..sort(), ['a', 'b', 'c']);
    expect(q..sort(), ['a', 'b', 'c']);
    expect((await phone.db.playlists()).where((l) => l.name == 'Drive').length, 1);
  });

  test('a playlist deleted on one device is deleted on the other only when the user agrees', () async {
    final a = await phone.song('a');
    final id = await phone.playlist('Drive', [a]);
    await settle();
    await phone.db.deletePlaylist(id);
    await phone.sync();
    await pc.sync(deleteOk: false);
    // Kept on the computer as an ordinary playlist.
    expect(await pc.titles('Drive'), ['a']);
    expect(await pc.engine.isSynced((await pc.idOf('Drive'))!), isFalse);
  });

  test('deleting with the user OK, and the same batch twice changes nothing', () async {
    final a = await phone.song('a');
    final id = await phone.playlist('Drive', [a]);
    await settle();
    await phone.db.deletePlaylist(id);
    await phone.sync();
    final r = await pc.sync();
    expect(r.deleted, ['Drive']);
    expect(await pc.idOf('Drive'), isNull);
    final again = await pc.sync();
    expect(again.changed, 0);
  });

  test('stopping sync keeps both copies and never brings the list back', () async {
    final a = await phone.song('a');
    await phone.playlist('Drive', [a]);
    await settle();
    final pcId = (await pc.idOf('Drive'))!;
    await pc.engine.disable(pcId);
    await settle();
    expect((await pc.db.playlists()).where((l) => l.name == 'Drive').length, 1);
    expect(await phone.titles('Drive'), ['a']);
  });

  test('liked songs sync when chosen', () async {
    final a = await phone.song('a');
    await pc.song('a');
    await phone.engine.setLikedSynced(true);
    await pc.engine.setLikedSynced(true);
    await phone.db.setFavorite(a, true);
    await settle();
    expect((await pc.db.favorites()).map((t) => t.title), ['a']);
    await phone.db.setFavorite(a, false);
    await settle();
    expect(await pc.db.favorites(), isEmpty);
  });

  test('a paused round goes on with the next sync', () async {
    final a = await phone.song('a');
    await phone.playlist('Drive', [a]);
    await phone.sync();
    await pc.sync();
    await phone.sync(); // the computer lacks a: planned
    expect(phone.engine.pending, 1);
    phone.engine.pause();
    await phone.transfer();
    expect(drive.songs, 0);
    phone.engine.resume();
    await settle();
    expect(await pc.titles('Drive'), ['a']);
  });

  test('a song removed on the device that has another copy is still sent', () async {
    final a = await phone.song('a');
    final copy = Track(id: '${a.id}.copy', uri: '${a.uri}.copy', title: 'a', artist: 'A', durationMs: 200000, source: TrackSource.local, addedAt: 1);
    File(copy.uri).writeAsStringSync('audio of a');
    await phone.db.upsertTracks([copy]);
    await phone.playlist('Drive', [a]);
    await phone.db.deleteTracks([copy.id]); // e.g. 移除重複的歌曲
    await settle();
    expect(await pc.titles('Drive'), ['a']);
  });

  test('a song removed from a library is not downloaded back there', () async {
    final a = await phone.song('a');
    await phone.playlist('Drive', [a]);
    await settle();
    final pcA = (await pc.db.tracks()).firstWhere((t) => t.title == 'a');
    await pc.db.deleteTracks([pcA.id]);
    await settle();
    expect(await pc.titles('Drive'), ['~a']);
    expect(await phone.titles('Drive'), ['a']);
    expect(drive.songs, 0);
  });

  test('a relay entry whose file is gone is sent again', () async {
    final a = await phone.song('a');
    await phone.playlist('Drive', [a]);
    await phone.sync();
    await pc.sync();
    await phone.sync();
    await phone.transfer();
    drive.files.removeWhere((_, f) => f.$1.startsWith('v2-song-'));
    await settle();
    expect(await pc.titles('Drive'), ['a']);
    expect(drive.songs, 0);
  });

  test('a song file the relay index lost is listed again', () async {
    final a = await phone.song('a');
    await phone.playlist('Drive', [a]);
    await phone.sync();
    await pc.sync();
    await phone.sync();
    await phone.transfer();
    final index = drive.files.entries.firstWhere((e) => e.value.$1.startsWith('v2-relay-'));
    drive.files[index.key] = (index.value.$1, Uint8List.fromList(utf8.encode('{}')), index.value.$3);
    await settle();
    expect(await pc.titles('Drive'), ['a']);
    expect(drive.songs, 0);
  });

  test('syncing while songs go up loses none of them', () async {
    final songs = [for (final n in ['a', 'b', 'c', 'd']) await phone.song(n)];
    await phone.playlist('Drive', songs);
    await phone.sync();
    await pc.sync();
    await phone.sync();
    await Future.wait([phone.transfer(), phone.sync(), phone.sync()]);
    await settle();
    expect(await pc.titles('Drive'), ['a', 'b', 'c', 'd']);
    expect(drive.songs, 0);
  });

  test('missing songs keep the sync going until both have them', () async {
    final a = await phone.song('a');
    await phone.playlist('Drive', [a]);
    await phone.sync();
    final r = await pc.sync();
    expect(r.incomplete, isTrue);
    await settle();
    expect((await pc.sync()).incomplete, isFalse);
  });

  test('a corrupted download never enters the library', () async {
    final a = await phone.song('a');
    await phone.playlist('Drive', [a]);
    await phone.sync();
    await pc.sync();
    await phone.sync();
    await phone.transfer();
    // Spoil the relayed file.
    final key = drive.files.entries.firstWhere((e) => e.value.$1.startsWith('v2-song-')).key;
    final f = drive.files[key]!;
    drive.files[key] = (f.$1, Uint8List.fromList(utf8.encode('broken')), f.$3);
    await pc.sync();
    await pc.transfer();
    expect(await pc.titles('Drive'), ['~a']);
  });

  test('a full relay waits; a song in two playlists goes up once', () async {
    final a = await phone.song('a');
    await phone.playlist('Drive', [a]);
    await phone.playlist('Car', [a]);
    await phone.sync();
    await pc.sync();
    await phone.sync();
    expect(phone.engine.pending, 1); // once for both playlists
    await phone.engine.runTransfers(relayCap: 1); // 1 byte: full
    expect(drive.songs, 0);
    await phone.engine.runTransfers(relayCap: 1 << 30);
    expect(drive.songs, 1);
    await settle();
    expect(await pc.titles('Drive'), ['a']);
    expect(await pc.titles('Car'), ['a']);
    expect(drive.songs, 0);
  });

  Future<Track> songOn(Device d, String title) async => (await d.db.tracks()).firstWhere((t) => t.title == title);

  Future<void> rename(Device d, String from, String to, {String? art}) async {
    final t = await songOn(d, from);
    await d.db.updateTrackInfo(Track(
        id: t.id, uri: t.uri, title: to, artist: t.artist, album: 'Album $to', durationMs: t.durationMs, art: art ?? t.art, source: t.source, addedAt: 1));
  }

  test('a song renamed on one device is renamed on the other, and stays in its playlists', () async {
    final a = await phone.song('a');
    await pc.song('a');
    await phone.playlist('Drive', [a]);
    await settle();
    await rename(phone, 'a', 'Apple');
    await settle();
    expect(await pc.titles('Drive'), ['Apple']);
    expect(await phone.titles('Drive'), ['Apple']);
    expect((await songOn(pc, 'Apple')).album, 'Album Apple');
    // Renamed again: the other device follows again.
    await rename(pc, 'Apple', 'Apricot');
    await settle();
    expect(await phone.titles('Drive'), ['Apricot']);
  });

  test('when both rename the same song, the later one wins on both', () async {
    final a = await phone.song('a');
    await pc.song('a');
    await phone.playlist('Drive', [a]);
    await settle();
    await rename(phone, 'a', 'First');
    await rename(pc, 'a', 'Second'); // later
    await settle();
    expect(await phone.titles('Drive'), ['Second']);
    expect(await pc.titles('Drive'), ['Second']);
  });

  test('a new cover goes to the other device through Drive, then leaves Drive', () async {
    final a = await phone.song('a');
    await pc.song('a');
    await phone.playlist('Drive', [a]);
    await settle();
    final art = File('${phone.dir.path}/cover.jpg')..writeAsBytesSync(List.filled(321, 7));
    await rename(phone, 'a', 'a', art: art.path);
    await settle();
    expect(File((await songOn(pc, 'a')).art!).lengthSync(), 321);
    expect(drive.files.values.where((f) => f.$1.startsWith('v2-cover-')), isEmpty);
  });

  test('songs outside the synced playlists keep their edits to themselves', () async {
    await phone.song('a');
    await pc.song('a');
    await settle();
    await rename(phone, 'a', 'Private');
    await settle();
    expect((await pc.db.tracks()).map((t) => t.title), ['a']);
  });

  test('lyrics picked by hand go to the other device', () async {
    final a = await phone.song('a');
    await pc.song('a');
    await phone.playlist('Drive', [a]);
    await settle();
    phone.lyrics[a.id] = (lrc: '[00:01]la la', manual: true, at: 5);
    await settle();
    final pcA = await songOn(pc, 'a');
    expect(pc.lyrics[pcA.id]?.lrc, '[00:01]la la');
    expect(pc.lyrics[pcA.id]?.manual, isTrue);
  });

  test('plays are counted on both, once, also of songs only one device has', () async {
    final a = await phone.song('a');
    await phone.song('b');
    await pc.song('a');
    final b = (await phone.db.tracks()).firstWhere((t) => t.title == 'b');
    final id = await phone.db.startListening(a, DateTime(2026, 3, 1));
    await phone.db.updateListening(id, const Duration(seconds: 90));
    await phone.db.startListening(b, DateTime(2026, 3, 2));
    await settle();
    await settle();
    final log = await pc.db.listening(DateTime(2026), DateTime(2027));
    expect(log.length, 2);
    final pcA = await songOn(pc, 'a');
    expect(log.firstWhere((e) => e.trackId == pcA.id).listened, const Duration(seconds: 90));
    // b isn't on the computer: its name is still there for the statistics.
    final remote = await pc.db.remoteSongs();
    expect(remote[log.firstWhere((e) => e.trackId != pcA.id).trackId]?.title, 'b');
    expect((await pc.db.playCounts())[pcA.id], 1);
    // The phone doesn't get its own plays back.
    expect((await phone.db.listening(DateTime(2026), DateTime(2027))).length, 2);
  });

  test('what plays on one device can be picked up on the other', () async {
    final store = NowPlayingStore(drive);
    await store.put(const NowPlaying(device: 'phone', deviceName: '手機', at: 99, songs: [
      {'t': 'a', 'a': 'A', 'ms': 200000},
      {'t': 'b', 'a': 'A', 'ms': 200000},
    ], index: 1, positionMs: 83000, original: [1, 0], loop: 'all'));
    await store.put(const NowPlaying(device: 'phone', deviceName: '手機', at: 100, songs: [{'t': 'c', 'a': 'A'}], index: 0, positionMs: 1000));
    final seen = await NowPlayingStore(drive).others('pc');
    expect(seen.length, 1); // one file per device, the latest
    expect(seen.single.current['t'], 'c');
    expect(await NowPlayingStore(drive).others('phone'), isEmpty);
  });

  test('sent and received count what really moved, once', () async {
    final a = await phone.song('a'), b = await phone.song('b');
    await pc.song('a');
    await pc.song('b');
    final id = await phone.playlist('Drive', [a, b]);
    await settle();
    await phone.db.removeFromPlaylist(id, 0);
    final out = await phone.sync();
    expect(out.sent, 1);
    expect(out.received, 0);
    final got = await pc.sync();
    expect(got.sent, 0);
    expect(got.received, greaterThan(0));
    // What came in isn't sent back as this device's own change.
    expect((await pc.sync()).sent, 0);
    expect((await phone.sync()).sent, 0);
  });

  test('another device is noticed only when it changed something, and the two do not keep answering', () async {
    final a = await phone.song('a');
    await pc.song('a');
    final id = await phone.playlist('Drive', [a]);
    await settle();
    await pc.sync();
    await phone.sync();
    expect(await phone.engine.othersChanged(), isFalse);
    expect(await pc.engine.othersChanged(), isFalse);
    await phone.db.renamePlaylist(id, 'Car');
    await phone.sync();
    expect(await pc.engine.othersChanged(), isTrue);
    await pc.sync();
    // Its merged list goes back once; then both are quiet.
    await phone.sync();
    await pc.sync();
    expect(await pc.engine.othersChanged(), isFalse);
    expect(await phone.engine.othersChanged(), isFalse);
  });

  group('接續播放', () {
    final now = DateTime(2026, 10, 30, 20);
    NowPlaying from(DateTime at) => NowPlaying(device: 'phone', deviceName: '手機', at: at.millisecondsSinceEpoch, songs: const [{'t': 'a', 'a': 'A'}], index: 0, positionMs: 1000);
    ResumeStep step(ResumeMode mode, {NowPlaying? latest, DateTime? here, bool playing = false, String? asked}) => resumeStep(
          mode: mode,
          latest: latest ?? from(now.subtract(const Duration(minutes: 5))),
          now: now,
          lastPlayedHere: here,
          playingHere: playing,
          asked: asked,
        ).step;

    test('asks, loads or leaves it by the setting', () {
      expect(step(ResumeMode.ask), ResumeStep.ask);
      expect(step(ResumeMode.auto), ResumeStep.load);
      expect(step(ResumeMode.never), ResumeStep.none);
      expect(ResumeMode.parse(null), ResumeMode.ask);
      expect(ResumeMode.parse('auto'), ResumeMode.auto);
    });

    test('automatic pick-up keeps the same limits as asking', () {
      final old = from(now.subtract(const Duration(hours: 13)));
      for (final mode in [ResumeMode.ask, ResumeMode.auto]) {
        expect(step(mode, latest: old), ResumeStep.none);
        expect(step(mode, playing: true), ResumeStep.none);
        expect(step(mode, here: now), ResumeStep.none);
        final latest = from(now.subtract(const Duration(minutes: 5)));
        expect(step(mode, latest: latest, asked: 'phone:${latest.at}'), ResumeStep.none);
      }
    });
  });

  test('merging is the same in either order', () {
    ListState make(String name, int at) => ListState(name: Stamped(name, at, 'x'));
    final a = make('A', 1), b = make('B', 2);
    expect(ListState.join(a, b).name!.value, ListState.join(b, a).name!.value);
  });
}
