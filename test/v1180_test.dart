import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart' show CancelToken, DioException, DioExceptionType, RequestOptions, Response;
import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/config/version.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/auto_backup.dart';
import 'package:ouoplayer/services/bug_report.dart';
import 'package:ouoplayer/services/download_service.dart';
import 'package:ouoplayer/services/network_check.dart';
import 'package:ouoplayer/services/sync/drive_client.dart';
import 'package:ouoplayer/services/usage_stats.dart';
import 'package:ouoplayer/ui/widgets/empty_state.dart';
import 'package:ouoplayer/ui/widgets/share_card.dart';

import 'sync2_test.dart' show Device, FakeDrive;
import 'v0120_test.dart' show openDb;

/// A Drive that counts what is fetched from it.
class CountingDrive implements DriveStore {
  final files = <String, (String, Uint8List, DateTime)>{};
  int downloads = 0;
  var _n = 0;
  var _clock = DateTime(2026, 11, 10);

  @override
  Future<List<DriveFile>> list() async => [for (final e in files.entries) DriveFile(e.key, e.value.$1, e.value.$3)];
  @override
  Future<Uint8List> download(String id) async {
    downloads++;
    return files[id]!.$2;
  }

  @override
  Future<String> upload(String name, List<int> bytes, {String? id, String mime = ''}) async {
    final key = id ?? 'f${_n++}';
    _clock = _clock.add(const Duration(seconds: 1));
    files[key] = (name, Uint8List.fromList(bytes), _clock);
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
}

Track song(String title, {int ms = 200000, String album = 'Al'}) =>
    Track(id: title, uri: title, title: title, artist: 'Ar', album: album, durationMs: ms, source: TrackSource.local, addedAt: 1);

void main() {
  group('同步省流量', () {
    test('an unchanged file is not fetched again', () async {
      final inner = CountingDrive();
      final id = await inner.upload('v2-ops-pc.json', utf8.encode('one'));
      final drive = CachedDrive(inner);
      await drive.list();
      expect(utf8.decode(await drive.download(id)), 'one');
      await drive.list();
      expect(utf8.decode(await drive.download(id)), 'one');
      expect(inner.downloads, 1);
    });

    test('a file another device changed is fetched again', () async {
      final inner = CountingDrive();
      final id = await inner.upload('v2-ops-pc.json', utf8.encode('one'));
      final drive = CachedDrive(inner);
      await drive.list();
      await drive.download(id);
      await inner.upload('v2-ops-pc.json', utf8.encode('two'), id: id); // the other device
      await drive.list();
      expect(utf8.decode(await drive.download(id)), 'two');
      expect(inner.downloads, 2);
    });

    test('a file written here is read back fresh, even before the next list', () async {
      final inner = CountingDrive();
      final id = await inner.upload('v2-prefs-me.json', utf8.encode('old'));
      final drive = CachedDrive(inner);
      await drive.list();
      await drive.download(id);
      await drive.upload('v2-prefs-me.json', utf8.encode('new'), id: id);
      expect(utf8.decode(await drive.download(id)), 'new');
    });

    test('a deleted file is forgotten', () async {
      final inner = CountingDrive();
      final id = await inner.upload('a.json', utf8.encode('x'));
      final drive = CachedDrive(inner);
      await drive.list();
      await drive.download(id);
      await drive.delete(id);
      expect((await drive.list()).where((f) => f.id == id), isEmpty);
    });

    test('two devices syncing again with nothing new fetch nothing', () async {
      final shared = FakeDrive();
      final phoneDrive = CachedDrive(shared);
      final pcDrive = CachedDrive(shared);
      final phone = await Device.make('phone', phoneDrive);
      final pc = await Device.make('pc', pcDrive);
      await phone.playlist('通勤', [await phone.song('a'), await phone.song('b')]);
      await phone.sync();
      await pc.sync();
      await phone.sync();
      await pc.sync();
      expect(await pc.titles('通勤'), ['~a', '~b']);
      final before = pcDrive.fetched;
      await pc.sync();
      await pc.sync();
      expect(pcDrive.fetched, before, reason: 'nothing changed on Drive');
      // A change on the phone is still picked up.
      final id = await phone.idOf('通勤');
      await phone.db.renamePlaylist(id!, '上班');
      await phone.sync();
      await pc.sync();
      expect(await pc.titles('上班'), ['~a', '~b']);
      expect(pcDrive.fetched, greaterThan(before));
    });

    test('the every-minute sync is only skipped on the phone', () async {
      // Off Android there is no mobile data check.
      expect(await everyMinuteSkipped(), isFalse);
    });
  });

  group('下載空清單', () {
    test('an empty list is read as empty, with a message that says why', () {
      final listing = PlaylistListing.parse('{"title": "2000-2009", "entries": []}');
      expect(listing, isNotNull);
      expect(listing!.entries, isEmpty);
      expect(canSplitPlaylist(listing.entries), isFalse);
      expect(emptyPlaylistMessage, isNotEmpty);
    });
  });

  group('備份資料夾', () {
    test('a picked folder is told apart from a path', () {
      expect(BackupTree.isTree('content://com.android.externalstorage.documents/tree/primary%3ADocuments'), isTrue);
      expect(BackupTree.isTree('/storage/emulated/0/Documents/OuOPlayer/備份'), isFalse);
      expect(BackupTree.isTree(r'C:\Users\x\Documents\OuOPlayer\備份'), isFalse);
    });

    test('path folders still back up, list and prune', () async {
      final db = await openDb();
      final dir = await Directory.systemTemp.createTemp('ouo_backup');
      for (var i = 0; i < 12; i++) {
        await AutoBackup.run(db, dir.path, now: DateTime(2026, 11, 1 + i, 3));
      }
      final files = await AutoBackup.list(dir.path);
      expect(files.length, AutoBackup.keep);
      expect(files.every((f) => f.automatic), isTrue);
      expect(files.map((f) => f.name), contains(AutoBackup.fileName(DateTime(2026, 11, 12, 3))));
      expect(files.map((f) => f.name), isNot(contains(AutoBackup.fileName(DateTime(2026, 11, 1, 3)))));
      final text = await readBackupText(files.first.path);
      expect((jsonDecode(text) as Map)['app'], 'OuOPlayer');
    });
  });

  group('匿名使用人數統計', () {
    test('a random id is 16 hex characters and differs each time', () {
      final a = UsageStats.newId();
      final b = UsageStats.newId();
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(a), isTrue);
      expect(a, isNot(b));
    });

    test('sent once a day, never when switched off', () {
      final now = DateTime(2026, 11, 10, 9);
      expect(UsageStats.due({}, now), isTrue);
      expect(UsageStats.due({UsageStats.dayKey: '2026-11-10'}, now), isFalse);
      expect(UsageStats.due({UsageStats.dayKey: '2026-11-9'}, now), isTrue);
      expect(UsageStats.due({UsageStats.onKey: 'false'}, now), isFalse);
    });

    test('only the id, version and platform are sent', () {
      final h = UsageStats.headers('0123456789abcdef');
      expect(h['x-ouo-id'], '0123456789abcdef');
      expect(h['x-ouo-ver'], appVersion);
      expect(h['x-ouo-platform'], anyOf('android', 'windows'));
      expect(h.keys.toSet(), {'x-ouo-app', 'x-ouo-id', 'x-ouo-ver', 'x-ouo-platform'});
    });

    test('the worker only accepts that shape', () {
      final src = File('cloud/update-worker/src/index.js').readAsStringSync();
      expect(src, contains("path === '/hello'"));
      expect(src, contains('/^[0-9a-f]{16}\$/'));
    });
  });

  group('品牌', () {
    test('回報問題 fills in the version and device, nothing else', () {
      final url = Uri.parse(BugReport.url('Samsung SM-S9180，Android 16 (API 36)'));
      expect(url.path, '/HowardWang818/OuOPlayer/issues/new');
      final body = url.queryParameters['body']!;
      expect(body, contains('OuOPlayer $appVersion'));
      expect(body, contains('Samsung SM-S9180'));
      expect(url.queryParameters.keys, ['body']);
    });

    test('這版新功能 has lines for this version', () {
      final lines = File('assets/whats_new.txt').readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
      expect(lines, isNotEmpty);
      expect(lines.length, lessThanOrEqualTo(8), reason: 'a short list');
    });

    test('the privacy policy tells about the count', () {
      final md = File('docs/PRIVACY.md').readAsStringSync();
      for (final text in [md]) {
        expect(text, contains('匿名使用人數'));
        expect(text, contains('不記錄 IP 位址'));
        expect(text, contains('90 天'));
      }
      expect(md, contains('Anonymous user count'));
    });

    test('share cards: tall for stories, square for posts, saved at 1080 px wide', () {
      expect(ShareShape.story.aspect, 9 / 16);
      expect(ShareShape.square.aspect, 1);
      expect(shareCardWidth * shareScale, 1080);
    });

    test('errors in plain words', () {
      final offline = DioException(requestOptions: RequestOptions(), type: DioExceptionType.connectionError);
      expect(isOffline(offline), isTrue);
      expect(friendlyError(offline), contains('網路'));
      final server = DioException(
          requestOptions: RequestOptions(), type: DioExceptionType.badResponse, response: Response(requestOptions: RequestOptions(), statusCode: 503));
      expect(isOffline(server), isFalse);
      expect(friendlyError(server), contains('稍後再試'));
      expect(friendlyError('x' * 300).length, lessThan(170));
    });

    test('the splash screen follows dark and light', () {
      const res = 'android/app/src/main/res';
      expect(File('$res/values/colors.xml').readAsStringSync(), contains('splash_background'));
      expect(File('$res/values-night/colors.xml').readAsStringSync(), contains('splash_background'));
      for (final d in ['values-v31', 'values-night-v31']) {
        expect(File('$res/$d/styles.xml').readAsStringSync(), contains('windowSplashScreenBackground'));
      }
      expect(File('$res/drawable/launch_background.xml').readAsStringSync(), contains('@color/splash_background'));
    });

    test('the signing password is not in the public build file', () {
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, contains('key.properties'));
      expect(RegExp(r'storePassword = "').hasMatch(gradle), isFalse);
    });

    test('the taskbar buttons keep the Windows folder settings untouched', () {
      final rc = File('windows/runner/Runner.rc').readAsStringSync();
      expect(rc, contains('IDI_THUMB_PLAY'));
      expect(rc, contains('"CompanyName", "com.ouo"'));
      expect(rc, contains('040904b0'));
    });
  });
}
