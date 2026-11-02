import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/db/database.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/backup.dart';
import 'package:ouoplayer/services/desktop_tray.dart';
import 'package:ouoplayer/services/library_scanner.dart';
import 'package:ouoplayer/services/native_names.dart';

import 'sync2_test.dart' show Device, FakeDrive;
import 'v0120_test.dart' show openDb;

Track _song(String uri, String title, {String artist = 'A'}) =>
    Track(id: uri, uri: uri, title: title, artist: artist, album: 'x', durationMs: 200000, source: TrackSource.local, addedAt: 1);

/// A backup as it goes into a file and comes back.
Future<Map<String, Object?>> _backup(AppDatabase db, Directory lyrics) async =>
    jsonDecode(jsonEncode(await buildBackup(db, lyricsDir: lyrics))) as Map<String, Object?>;

/// A backup from before v1.14.4: it lists no library, covers or lyrics.
Map<String, Object?> _old(Map<String, Object?> b) => {
      for (final e in b.entries)
        if (!const {'library', 'track_edits', 'covers', 'lyrics'}.contains(e.key)) e.key: e.value,
      'playlists': [
        for (final pl in (b['playlists'] as List).cast<Map>())
          {
            for (final e in pl.entries)
              if (!const {'uid', 'synced', 'items'}.contains(e.key)) e.key: e.value,
          },
      ],
    };

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('ouo_1144'));

  test('the window starts hidden only with the tray on', () {
    expect(DesktopTray.startsHidden(['--tray'], trayOn: true), isTrue);
    expect(DesktopTray.startsHidden(['--tray'], trayOn: false), isFalse);
    expect(DesktopTray.startsHidden([], trayOn: true), isFalse);
  });

  group('a new install', () {
    late AppDatabase phone, fresh;
    setUp(() async {
      phone = await openDb();
      fresh = await openDb();
      // The phone holds the original name only in the app.
      await phone.upsertTracks([_song('/m/a.m4a', 'Yoru ni Kakeru'), _song('/m/b.m4a', 'other')]);
      await phone.updateTrackInfo(_song('/m/a.m4a', '夜に駆ける', artist: 'YOASOBI'));
      final id = await phone.createPlaylist('Liked');
      await phone.addToPlaylist(id, [(await phone.track('/m/a.m4a'))!], allowDuplicates: true);
      // After the reinstall the scan reads the old names from the files.
      await fresh.upsertTracks([_song('/m/a.m4a', 'Yoru ni Kakeru'), _song('/m/b.m4a', 'other')]);
    });

    test('gets the names back from a backup', () async {
      final b = await _backup(phone, tmp);
      final report = await restoreBackup(fresh, LibraryScanner(fresh), b, coverDir: tmp, lyricsDir: tmp);
      expect(report.renamed, 1);
      expect((await fresh.track('/m/a.m4a'))!.title, '夜に駆ける');
      expect((await fresh.track('/m/a.m4a'))!.artist, 'YOASOBI');
      expect((await fresh.track('/m/b.m4a'))!.title, 'other');
    });

    test('gets them back from an older backup too, by the lists it names them in', () async {
      final b = _old(await _backup(phone, tmp));
      await restoreBackup(fresh, LibraryScanner(fresh), b, coverDir: tmp, lyricsDir: tmp);
      expect((await fresh.track('/m/a.m4a'))!.title, '夜に駆ける');
    });

    test('an older backup also renames songs in no list, by its rename notes', () async {
      await phone.upsertTracks([_song('/m/c.m4a', 'Gunjo')]);
      await NativeNames.rememberRename(phone, _song('/m/c.m4a', 'Gunjo'), _song('/m/c.m4a', '群青'));
      await fresh.upsertTracks([_song('/m/c.m4a', 'Gunjo')]);
      final b = _old(await _backup(phone, tmp));
      await restoreBackup(fresh, LibraryScanner(fresh), b, coverDir: tmp, lyricsDir: tmp);
      expect((await fresh.track('/m/c.m4a'))!.title, '群青');
    });

    test('names are left alone when only other parts are restored', () async {
      final b = await _backup(phone, tmp);
      await restoreBackup(fresh, LibraryScanner(fresh), b, coverDir: tmp, lyricsDir: tmp, parts: {RestorePart.playlists});
      expect((await fresh.track('/m/a.m4a'))!.title, 'Yoru ni Kakeru');
    });

    test('lyrics come back, and a newer copy here is kept', () async {
      final kept = await tmp.createTemp('from');
      File('${kept.path}/a.json').writeAsStringSync('{"lrc":"old"}');
      File('${kept.path}/b.json').writeAsStringSync('{"lrc":"mine"}');
      final b = await _backup(phone, kept);
      final here = await tmp.createTemp('to');
      File('${here.path}/b.json').writeAsStringSync('{"lrc":"newer"}');
      await restoreBackup(fresh, LibraryScanner(fresh), b, coverDir: tmp, lyricsDir: here);
      expect(File('${here.path}/a.json').readAsStringSync(), '{"lrc":"old"}');
      expect(File('${here.path}/b.json').readAsStringSync(), '{"lrc":"newer"}');
    });

    test("a device's sync state stays out of backups", () async {
      await phone.setSetting('sync2_sent_lists', '{}');
      await phone.setSetting('sync_names', '{}');
      final settings = (await _backup(phone, tmp))['settings'] as Map;
      expect(settings.containsKey('sync2_sent_lists'), isFalse);
      expect(settings.containsKey('sync_names'), isTrue);
    });
  });

  group('reinstalling on a synced device', () {
    late FakeDrive drive;
    late Device phone, pc;
    late Track a;

    setUp(() async {
      drive = FakeDrive();
      phone = await Device.make('phone', drive);
      pc = await Device.make('pc', drive);
      a = await phone.song('a');
      await pc.song('a');
      await phone.playlist('Liked', [a]);
      for (var i = 0; i < 2; i++) {
        await phone.sync();
        await pc.sync();
      }
      expect(await pc.titles('Liked'), ['a']);
    });

    /// The same phone after a reinstall: a new device, restored from [backup].
    Future<Device> reinstall(Map<String, Object?> backup) async {
      final again = await Device.make('phone2', drive);
      await again.db.upsertTracks([Track(id: a.id, uri: a.uri, title: 'a', artist: 'A', durationMs: 200000, source: TrackSource.local, addedAt: 1)]);
      await restoreBackup(again.db, LibraryScanner(again.db), backup, coverDir: tmp, lyricsDir: tmp);
      return again;
    }

    Future<int> lists(Device d) async => (await d.db.db.query('playlists', where: 'name = ?', whereArgs: ['Liked'])).length;

    test('keeps one list with a backup of this version', () async {
      final again = await reinstall(await _backup(phone.db, tmp));
      await again.sync();
      expect(await lists(again), 1);
      expect(await again.titles('Liked'), ['a']);
    });

    test('keeps one list with an older backup', () async {
      final again = await reinstall(_old(await _backup(phone.db, tmp)));
      await again.sync();
      expect(await lists(again), 1);
      expect(await again.titles('Liked'), ['a']);
    });

    test('deleting the only list after that asks the other device as usual', () async {
      final again = await reinstall(_old(await _backup(phone.db, tmp)));
      await again.sync();
      await again.db.deletePlaylist((await again.idOf('Liked'))!);
      await again.sync();
      await pc.sync(deleteOk: false);
      // The answer was 保留.
      expect(await pc.titles('Liked'), ['a']);
    });
  });

  test('a rename from before edits were recorded reaches the other device', () async {
    final drive = FakeDrive();
    final phone = await Device.make('phone', drive), pc = await Device.make('pc', drive);
    final before = await phone.song('Gunjo');
    await pc.song('Gunjo');
    // Renamed the old way: the library and the notes, no edit.
    await phone.db.db.update('tracks', {'title': '群青'}, where: 'id = ?', whereArgs: [before.id]);
    await NativeNames.rememberRename(phone.db, before, Track(id: before.id, uri: before.uri, title: '群青', artist: 'A', durationMs: 200000));
    await phone.playlist('L', [(await phone.db.track(before.id))!]);
    await pc.playlist('L', [], sync: true);
    for (var i = 0; i < 3; i++) {
      await phone.sync();
      await pc.sync();
    }
    final there = await pc.db.tracks();
    expect(there.any((t) => t.title == '群青'), isTrue);
  });
}
