// 1.23.0: the plays two devices heard add up, backups without song covers,
// cleaning up the old backups, and the network check. (接續播放's tests went
// with it in 1.24.0.)
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/app.dart' show rootNavigatorKey;
import 'package:ouoplayer/providers/auto_backup_provider.dart';
import 'package:ouoplayer/services/auto_backup.dart';
import 'package:ouoplayer/ui/widgets/backup_cleanup.dart';
import 'package:ouoplayer/data/db/database.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/providers/providers.dart';
import 'package:ouoplayer/providers/sync_provider.dart';
import 'package:ouoplayer/services/backup.dart';
import 'package:ouoplayer/services/library_scanner.dart';
import 'package:ouoplayer/services/network_check.dart';

import 'sync_scenarios/harness.dart';
import 'v0120_test.dart' show openDb;

Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

/// Stores covers in [dir] (the app's own folder needs the platform).
class CoverScanner extends LibraryScanner {
  CoverScanner(super.db, this.dir);
  final Directory dir;

  @override
  Future<String> storeArt(Uint8List bytes, String mime) async =>
      (File('${dir.path}/stored_${bytes.length}.jpg')..writeAsBytesSync(bytes)).path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => debugSyncAvailable = true);
  tearDown(() => debugSyncAvailable = null);

  group('收聽秒數', () {
    test('15 → 16：舊紀錄留著，分不開的照舊', () async {
      final app = await openDb();
      await app.db.execute('DROP TABLE listening_log');
      await app.db.execute('CREATE TABLE listening_log(id INTEGER PRIMARY KEY, track_id TEXT, played_at INTEGER, listened_ms INTEGER, '
          'source TEXT, estimated INTEGER DEFAULT 0, origin TEXT, remote_id TEXT)');
      await app.db.insert('listening_log', {'track_id': 'x', 'played_at': 1, 'listened_ms': 7000});
      await AppDatabase.migrate(app.db, 15, 16);
      final row = (await app.db.query('listening_log')).single;
      expect((row['listened_ms'], row['parts']), (7000, null));
    });

    test('還原到同一台、新裝的：都不會算兩次', () async {
      final cloud = Cloud();
      final a = await Dev.make('A', cloud);
      final b = await Dev.make('B', cloud);
      await a.song('a');
      await b.song('a');
      final began = await a.play('a', seconds: 60);
      await settle([a, b]);
      await b.carryOn('a', began, 60000, seconds: 40, parts: {'A': 60000});
      await settle([a, b]);
      expect(await a.heard('a'), [100]);

      final dir = await Directory.systemTemp.createTemp('ouo_parts');
      final backup = jsonDecode(jsonEncode(await buildBackup(a.db, lyricsDir: dir))) as Map<String, dynamic>;
      await restoreBackup(a.db, LibraryScanner(a.db), backup, coverDir: dir, lyricsDir: dir, parts: {RestorePart.history});
      await settle([a, b]);
      expect(await a.heard('a'), [100]);
      expect(await b.heard('a'), [100]);
      await expectStable([a, b]);

      final again = await a.reinstall();
      await restoreBackup(again.db, LibraryScanner(again.db), backup, coverDir: dir, lyricsDir: dir, parts: {RestorePart.history});
      await settle([again, b]);
      expect(await again.heard('a'), [100]);
      expect(await b.heard('a'), [100]);
      await expectStable([again, b]);
    });

    test('只有一台聽過的播放：備份不多存東西', () async {
      final cloud = Cloud();
      final a = await Dev.make('A', cloud);
      final b = await Dev.make('B', cloud);
      await a.song('a');
      await b.song('a');
      await a.play('a', seconds: 60);
      await settle([a, b]);
      final dir = await Directory.systemTemp.createTemp('ouo_plain');
      for (final d in [a, b]) {
        final plays = (await buildBackup(d.db, lyricsDir: dir))['listening'] as List;
        expect((plays.single as Map).containsKey('parts'), isFalse, reason: d.name);
      }
    });

    test('這台的狀態不進備份', () async {
      final app = await openDb();
      await app.setSetting('sync2_now', '{}');
      await app.setSetting('sync2_now_kept', '[]');
      final dir = await Directory.systemTemp.createTemp('ouo_state');
      final settings = (await buildBackup(app, lyricsDir: dir))['settings'] as Map;
      expect(settings.keys.where((k) => '$k'.startsWith('sync2_now')), isEmpty);
    });
  });

  group('備份大小', () {
    late Dev a;
    late Directory dir;
    late List<int> picture;
    setUp(() async {
      a = await Dev.make('A', Cloud());
      dir = await Directory.systemTemp.createTemp('ouo_backup');
      picture = List.filled(300 * 1024, 7);
      for (var i = 0; i < 30; i++) {
        final t = await a.song('s$i');
        final art = File('${dir.path}/c$i.jpg')..writeAsBytesSync(picture);
        // As after a download: the official cover, changed by nobody's hand.
        await a.db.updateTrackInfo(
            Track(id: t.id, uri: t.uri, title: t.title, artist: t.artist, album: t.album, durationMs: t.durationMs, art: art.path, source: t.source, addedAt: t.addedAt));
      }
    });

    Future<Map<String, dynamic>> backup() async => jsonDecode(jsonEncode(await buildBackup(a.db, lyricsDir: dir))) as Map<String, dynamic>;

    test('歌曲封面不進備份：30 首不到 0.1 MB', () async {
      final b = await backup();
      expect(b.containsKey('covers'), isFalse);
      expect(utf8.encode(jsonEncode(b)).length, lessThan(100 * 1024));
    });

    test('播放清單自訂封面照存、還原得回來', () async {
      final id = await a.db.createPlaylist('L');
      final cover = File('${dir.path}/list.jpg')..writeAsStringSync('list cover');
      await a.db.db.update('playlists', {'cover': cover.path}, where: 'id = ?', whereArgs: [id]);
      final b = await backup();
      final fresh = await openDb();
      await restoreBackup(fresh, LibraryScanner(fresh), b, coverDir: dir, lyricsDir: dir);
      final restored = (await fresh.db.query('playlists', where: "name = 'L'")).single['cover'] as String;
      expect(File(restored).readAsStringSync(), 'list cover');
    });

    test('還原到同一台：現有的歌曲封面不會不見', () async {
      final before = (await a.track('s3')).art;
      await restoreBackup(a.db, LibraryScanner(a.db), await backup(), coverDir: dir, lyricsDir: dir);
      expect((await a.track('s3')).art, before);
    });

    test('舊備份裡的封面照樣還原', () async {
      final t = await a.track('s3');
      final b = await backup();
      b['covers'] = {t.uri: base64Encode(utf8.encode('old backup cover'))};
      await restoreBackup(a.db, CoverScanner(a.db, dir), b, coverDir: dir, lyricsDir: dir, parts: {RestorePart.songs});
      expect(File((await a.track('s3')).art!).readAsStringSync(), 'old backup cover');
    });
  });

  group('清理舊備份', () {
    test('認得含封面的備份（縮排或不縮排）', () {
      List<int> b(Object v, {bool indent = true}) => utf8.encode(indent ? const JsonEncoder.withIndent(' ').convert(v) : jsonEncode(v));
      expect(AutoBackup.holdsCovers(b({'app': 'OuOPlayer', 'covers': {'/m/a': 'AAAA'}})), isTrue);
      expect(AutoBackup.holdsCovers(b({'app': 'OuOPlayer', 'covers': {'/m/a': 'AAAA'}}, indent: false)), isTrue);
      expect(AutoBackup.holdsCovers(b({'app': 'OuOPlayer', 'covers': {}})), isFalse);
      expect(AutoBackup.holdsCovers(b({'app': 'OuOPlayer', 'playlists': [{'cover': 'BBBB'}]})), isFalse);
      expect(AutoBackup.holdsCovers(b({'app': 'OuOPlayer'})), isFalse);
    });

    late Directory folder;
    late AppDatabase db;
    late ProviderContainer c;

    File put(String name, Map<String, Object?> body) =>
        File('${folder.path}/$name')..writeAsStringSync(const JsonEncoder.withIndent(' ').convert(body));
    List<String> names() => [for (final f in folder.listSync()) f.uri.pathSegments.last]..sort();

    Future<void> run(WidgetTester t, Future<void> Function(Future<void> asked) body, {bool first = false}) async {
      await t.pumpWidget(MaterialApp(navigatorKey: rootNavigatorKey, home: const Scaffold()));
      await t.runAsync(() async {
        folder = await Directory.systemTemp.createTemp('ouo_old_backups');
        db = await openDb();
        c = ProviderContainer(overrides: [dbProvider.overrideWithValue(db)]);
        c.read(autoBackupProvider);
        await wait(100);
        await c.read(autoBackupProvider.notifier).setDir(folder.path);
        for (var i = 1; i <= 3; i++) {
          put('${AutoBackup.prefix}2026-11-0${i}_030000.json', {'app': 'OuOPlayer', 'covers': {'/m/$i': 'AAAA'}});
        }
        put('${AutoBackup.prefix}2026-11-23_030000.json', {'app': 'OuOPlayer'});
        put('OuOPlayer備份_2026-11-01.json', {'app': 'OuOPlayer', 'covers': {'/m/x': 'AAAA'}});
        final ctx = t.element(find.byType(Scaffold));
        final asked = offerBackupCleanup(ctx, db, c.read(autoBackupProvider.notifier), folder.path);
        await body(asked);
        await asked.timeout(const Duration(seconds: 5));
        c.dispose();
      });
      // The top message goes away by itself.
      await t.pump(const Duration(seconds: 10));
      await t.pump(const Duration(seconds: 10));
    }

    Future<bool> shows(WidgetTester t, String text) async {
      for (var i = 0; i < 30; i++) {
        await wait(50);
        await t.pump();
        await t.pump(const Duration(milliseconds: 300));
        if (find.text(text).evaluate().isNotEmpty) return true;
      }
      return false;
    }

    Future<void> tap(WidgetTester t, String text) async {
      await t.tap(find.text(text).last);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
    }

    testWidgets('清理：先存新備份再刪，只刪含封面的自動備份', (t) async {
      await run(t, (asked) async {
        expect(await shows(t, '要清理舊備份嗎？'), isTrue);
        expect(find.textContaining('3 份舊的自動備份'), findsOneWidget);
        await tap(t, '清理');
        expect(await shows(t, '刪除這 3 份舊備份？'), isTrue);
        await tap(t, '刪除');
        await asked;
        final left = names();
        expect(left.where((n) => n.startsWith('${AutoBackup.prefix}2026-11-0')), isEmpty);
        expect(left, contains('${AutoBackup.prefix}2026-11-23_030000.json'));
        expect(left, contains('OuOPlayer備份_2026-11-01.json'));
        expect(left.length, 3, reason: 'the new backup is there');
        expect(await db.allSettings().then((m) => m[backupCleanupKey]), 'cleaned');
        await t.pump(const Duration(milliseconds: 300));
        final message = find.textContaining('已清理 3 份舊備份');
        expect(message, findsOneWidget);
        // At the top, like every message.
        expect(t.getTopLeft(message).dy, lessThan(t.view.physicalSize.height / t.view.devicePixelRatio / 3));
      });
    });

    testWidgets('保留：都不刪，之後不再問', (t) async {
      await run(t, (asked) async {
        expect(await shows(t, '要清理舊備份嗎？'), isTrue);
        await tap(t, '保留');
        await asked;
        expect(names().length, 5);
        expect(await db.allSettings().then((m) => m[backupCleanupKey]), 'kept');
        await offerBackupCleanup(rootNavigatorKey.currentContext!, db, c.read(autoBackupProvider.notifier), folder.path);
        await t.pump();
        expect(find.text('要清理舊備份嗎？'), findsNothing);
      });
    });

    testWidgets('第二個確認按取消：都不刪', (t) async {
      await run(t, (asked) async {
        expect(await shows(t, '要清理舊備份嗎？'), isTrue);
        await tap(t, '清理');
        expect(await shows(t, '刪除這 3 份舊備份？'), isTrue);
        await tap(t, '取消');
        await asked;
        expect(names().length, 5);
      });
    });

    testWidgets('新備份寫不進去：舊的不刪', (t) async {
      await run(t, (asked) async {
        expect(await shows(t, '要清理舊備份嗎？'), isTrue);
        // The folder can't be written any more: a file stands in its place.
        await c.read(autoBackupProvider.notifier).setDir('${folder.path}/${AutoBackup.prefix}2026-11-23_030000.json');
        await tap(t, '清理');
        expect(await shows(t, '刪除這 3 份舊備份？'), isTrue);
        await tap(t, '刪除');
        await asked;
        expect(names().length, 5);
        await t.pump(const Duration(milliseconds: 300));
        final message = find.textContaining('備份失敗，舊備份沒有刪除');
        expect(message, findsOneWidget);
        expect(t.getTopLeft(message).dy, lessThan(t.view.physicalSize.height / t.view.devicePixelRatio / 3));
      });
    });
  });

  group('行動數據', () {
    test('判斷不出來：不傳歌', () async {
      expect(await songsMayTransfer(() async => null), isFalse);
      expect(await songsMayTransfer(() async => true), isFalse);
      expect(await songsMayTransfer(() async => false), isTrue);
    });

    test('網路判斷不靠 MainActivity', () {
      final activity = File('android/app/src/main/kotlin/com/ouo/ouoplayer/MainActivity.kt').readAsStringSync();
      expect(activity, isNot(contains('MethodChannel(messenger, "ouo/network")')));
      final plugin = File('third_party/ouo_network/android/src/main/java/com/ouo/network/OuoNetworkPlugin.java').readAsStringSync();
      expect(plugin, contains('"ouo/network"'));
      expect(File('pubspec.yaml').readAsStringSync(), contains('path: third_party/ouo_network'));
    });
  });
}

