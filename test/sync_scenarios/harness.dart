// Shared set-up for the sync scenario tests: devices with their own library
// (database + music folder), one in-memory Google Drive, one clock.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/db/database.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/sync/drive_client.dart';
import 'package:ouoplayer/services/sync2/engine.dart';
import 'package:ouoplayer/services/sync2/now_playing.dart';
import 'package:ouoplayer/services/sync2/sync_log.dart';

import '../v0120_test.dart' show openDb;

/// One clock for every device (ms), moving 1 s per reading.
class Clock {
  static int now = DateTime(2026, 11, 13, 9).millisecondsSinceEpoch;
  static int tick() => now += 1000;
  static void pass(Duration d) => now += d.inMilliseconds;
}

/// Google Drive's app folder, in memory. [offline] makes every call fail.
class Cloud implements DriveStore {
  final files = <String, (String name, Uint8List bytes, DateTime modified)>{};
  var _n = 0;
  bool offline = false;
  var writes = 0;

  void _check() {
    if (offline) throw const SocketException('offline');
  }

  @override
  Future<List<DriveFile>> list() async {
    _check();
    return [for (final e in files.entries) DriveFile(e.key, e.value.$1, e.value.$3)];
  }

  @override
  Future<Uint8List> download(String id) async {
    _check();
    return files[id]!.$2;
  }

  @override
  Future<String> upload(String name, List<int> bytes, {String? id, String mime = ''}) async {
    _check();
    writes++;
    final key = id ?? 'f${_n++}';
    files[key] = (name, Uint8List.fromList(bytes), DateTime.fromMillisecondsSinceEpoch(Clock.tick()));
    return key;
  }

  @override
  Future<String> uploadFile(String name, File file, {String mime = '', void Function(int, int)? onProgress, CancelToken? cancel}) async =>
      upload(name, await file.readAsBytes());

  @override
  Future<void> downloadTo(String id, String path, {void Function(int, int)? onProgress, CancelToken? cancel}) async {
    _check();
    await File(path).writeAsBytes(files[id]!.$2);
  }

  @override
  Future<void> delete(String id) async {
    _check();
    files.remove(id);
  }

  int count(String prefix) => files.values.where((f) => f.$1.startsWith(prefix)).length;
  List<String> names(String prefix) => [for (final f in files.values) if (f.$1.startsWith(prefix)) f.$1]..sort();

  /// Every file's name and content, to tell whether anything was written.
  String get fingerprint => ([for (final f in files.values) '${f.$1}:${sha256.convert(f.$2)}']..sort()).join('\n');
}

/// A device: its library (database + music folder), lyrics and sync engine.
/// A song file holds its tags as JSON, so the receiving device reads the
/// sender's file tags, like a real scan.
class Dev {
  Dev._(this.name, this.id, this.db, this.dir, this.cloud);
  final String name;
  final String id;
  final AppDatabase db;
  final Directory dir;
  final Cloud cloud;
  late SyncEngine engine;
  final lyrics = <String, ({String lrc, bool manual, int at})>{};

  static Future<Dev> make(String name, Cloud cloud, {String? id, Directory? dir}) async {
    final db = await openDb();
    final d = Dev._(name, id ?? name, db, dir ?? await Directory.systemTemp.createTemp('ouo_$name'), cloud);
    Directory('${d.dir.path}/music').createSync(recursive: true);
    d.engine = SyncEngine(
      db: db,
      drive: cloud,
      deviceId: () async => d.id,
      deviceName: name,
      importFile: (path) async {
        final tags = jsonDecode(File(path).readAsStringSync()) as Map;
        final t = Track(
            id: path, uri: path, title: '${tags['t']}', artist: '${tags['a']}', album: '${tags['al']}', durationMs: tags['ms'] as int,
            source: TrackSource.download, addedAt: Clock.tick());
        await db.upsertTracks([t]);
        return t;
      },
      storeArt: (bytes, mime) async {
        final f = File('${d.dir.path}/art_${sha256.convert(bytes).toString().substring(0, 12)}.jpg')..writeAsBytesSync(bytes);
        return f.path;
      },
      lyricsOf: (t) async => d.lyrics[t.id],
      setLyrics: (t, lrc, manual) async => d.lyrics[t.id] = (lrc: lrc, manual: manual, at: Clock.tick()),
      downloadDir: () => '${d.dir.path}/dl',
      clock: Clock.tick,
    );
    return d;
  }

  /// The same device after the app was removed and installed again: an
  /// empty database, a new device id, the music files still there (scanned).
  Future<Dev> reinstall({String? newId}) async {
    final d = await make(name, cloud, id: newId ?? '$id-new', dir: dir);
    await d.scan();
    return d;
  }

  /// A scan of the music and download folders (tags from the files).
  Future<void> scan() async {
    final found = <Track>[];
    for (final folder in ['music', 'dl']) {
      final f = Directory('${dir.path}/$folder');
      if (!f.existsSync()) continue;
      for (final file in f.listSync().whereType<File>()) {
        final tags = jsonDecode(file.readAsStringSync()) as Map;
        found.add(Track(
            id: file.path, uri: file.path, title: '${tags['t']}', artist: '${tags['a']}', album: '${tags['al']}', durationMs: tags['ms'] as int,
            source: folder == 'dl' ? TrackSource.download : TrackSource.local, addedAt: 1));
      }
    }
    await db.upsertTracks(found);
  }

  /// A song file here (its tags are its names unless [fileTitle] differs).
  Future<Track> song(String title, {String artist = 'A', int ms = 200000, String album = 'x', String? fileTitle, String? file}) async {
    final f = File('${dir.path}/music/${file ?? title}.mp3')
      ..writeAsStringSync(jsonEncode({'t': fileTitle ?? title, 'a': artist, 'al': album, 'ms': ms, 'n': name}));
    final t = Track(id: f.path, uri: f.path, title: title, artist: artist, album: album, durationMs: ms, source: TrackSource.local, addedAt: Clock.tick());
    await db.upsertTracks([t]);
    return t;
  }

  Future<Track> track(String title) async => (await db.tracks()).firstWhere((t) => t.title == title);
  Future<Track?> trackOrNull(String title) async => (await db.tracks()).where((t) => t.title == title).firstOrNull;
  Future<List<String>> library() async => [for (final t in await db.tracks()) t.title]..sort();

  /// 新增播放清單 (and 同步這個清單 unless [sync] is false).
  Future<int> playlist(String name, List<Track> songs, {bool sync = true}) async {
    final id = await db.createPlaylist(name);
    if (songs.isNotEmpty) await db.addToPlaylist(id, songs, allowDuplicates: true);
    if (sync) await engine.enable(id);
    return id;
  }

  Future<int?> idOf(String name) async => (await db.db.query('playlists', where: 'name = ?', whereArgs: [name])).firstOrNull?['id'] as int?;
  Future<int> listId(String name) async => (await idOf(name))!;
  Future<List<String>> listNames() async => [for (final p in await db.playlists()) p.name]..sort();

  /// Titles in a playlist, '~' marking a greyed song this device doesn't have.
  Future<List<String>> titles(String name) async {
    final id = await idOf(name);
    if (id == null) return const ['<no such playlist>'];
    return [for (final t in await db.playlistTracks(id)) t.source == TrackSource.missing ? '~${t.title}' : t.title];
  }

  Future<List<String>> liked() async => [for (final t in await db.favorites()) t.title]..sort();

  Future<void> like(String title, [bool on = true]) async => db.setFavorite(await track(title), on);

  /// 編輯資訊.
  Future<void> rename(String title, String to, {String? artist, String? album}) async {
    final t = await track(title);
    await db.updateTrackInfo(Track(
        id: t.id, uri: t.uri, title: to, artist: artist ?? t.artist, album: album ?? t.album, durationMs: t.durationMs, art: t.art,
        source: t.source, trackNo: t.trackNo, addedAt: t.addedAt));
  }

  /// 找封面 / 更換封面: a new cover file for the song.
  Future<String> setCover(String title, String picture) async {
    final t = await track(title);
    final f = File('${dir.path}/cover_${picture}_${Clock.tick()}.jpg')..writeAsStringSync('picture $picture');
    await db.updateTrackInfo(Track(
        id: t.id, uri: t.uri, title: t.title, artist: t.artist, album: t.album, durationMs: t.durationMs, art: f.path, source: t.source,
        trackNo: t.trackNo, addedAt: t.addedAt));
    return 'picture $picture';
  }

  Future<String?> cover(String title) async {
    final art = (await track(title)).art;
    return art == null || !File(art).existsSync() ? null : File(art).readAsStringSync();
  }

  /// A play of [title] here, [seconds] long.
  Future<void> play(String title, {int seconds = 60}) async {
    final id = await db.startListening(await track(title), DateTime.fromMillisecondsSinceEpoch(Clock.tick()));
    await db.updateListening(id, Duration(seconds: seconds));
  }

  Future<int> plays() async => (await db.db.query('listening_log')).length;
  Future<int> playsOf(String title) async {
    final t = await track(title);
    return (await db.db.query('listening_log', where: 'track_id = ?', whereArgs: [t.id])).length;
  }

  Future<void> set(String key, String value) => db.setSetting(key, value);
  Future<String?> setting(String key) async => (await db.allSettings())[key];

  Future<List<String>> log() async => [for (final e in await SyncLog.read(db)) e.text];

  /// 立即同步.
  Future<SyncResult> sync() => engine.sync();

  Future<int> transfer({int cap = 1 << 30}) => engine.runTransfers(relayCap: cap);

  /// What plays here, as 接續播放 sends it.
  Future<void> nowPlaying(List<String> queue, {int index = 0, int positionMs = 30000, int? at}) async {
    final lib = {for (final t in await db.tracks()) t.title: t};
    await engine.nowPlaying.put(NowPlaying(
      device: id,
      deviceName: name,
      at: at ?? Clock.tick(),
      songs: [for (final q in queue) SyncEngine.ref(lib[q]!)],
      index: index,
      positionMs: positionMs,
    ));
  }

  /// Everything a user sees of the library, to tell whether a sync changed anything.
  Future<String> fingerprint() async {
    final parts = <String>[];
    for (final t in await db.tracks()) {
      parts.add('track ${t.title}|${t.artist}|${t.album}|${t.art}');
    }
    for (final p in await db.playlists()) {
      parts.add('list ${p.name}: ${(await titles(p.name)).join(',')}');
    }
    parts.add('liked ${(await liked()).join(',')}');
    parts.add('plays ${await plays()}');
    parts.add('lyrics ${[for (final e in lyrics.entries) '${e.key}=${e.value.lrc}'].join(',')}');
    final s = await db.allSettings();
    parts.add('theme ${s['color_theme']} ${s['color_theme_at']}');
    return (parts..sort()).join('\n');
  }
}

/// Everyone syncs and moves songs until nothing changes.
Future<void> settle(List<Dev> devs, {int rounds = 5}) async {
  for (var i = 0; i < rounds; i++) {
    for (final d in devs) {
      await d.sync();
      await d.transfer();
    }
  }
}

/// After [settle]: more syncs change nothing anywhere — no library change, no
/// file written to Drive, no line in 同步紀錄, nothing received or still missing.
Future<void> expectStable(List<Dev> devs, {bool complete = true}) async {
  await settle(devs, rounds: 1);
  final cloud = devs.first.cloud;
  final before = cloud.fingerprint;
  final libs = [for (final d in devs) await d.fingerprint()];
  final logs = [for (final d in devs) (await d.log()).length];
  for (var round = 0; round < 3; round++) {
    for (final d in devs) {
      final r = await d.sync();
      expect(r.received, 0, reason: '${d.name} received something in round $round');
      expect(r.changed, 0, reason: '${d.name} changed its library in round $round');
      if (complete) expect(r.incomplete, isFalse, reason: '${d.name} still thinks a song is missing');
      expect(r.uploads + r.downloads, 0, reason: '${d.name} still plans songs to move');
    }
  }
  expect(cloud.fingerprint, before, reason: 'Drive was written again');
  for (var i = 0; i < devs.length; i++) {
    expect(await devs[i].fingerprint(), libs[i], reason: '${devs[i].name} library changed');
    expect((await devs[i].log()).length, logs[i], reason: '${devs[i].name} logged more');
  }
}
