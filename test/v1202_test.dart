import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/sync2/edits.dart';
import 'package:ouoplayer/services/sync2/merge.dart';
import 'package:ouoplayer/ui/pages/settings/sync_settings.dart';

import 'sync2_test.dart' show FakeDrive;
import 'v0120_test.dart' show openDb;

void main() {
  group('接續播放狀態', () {
    test('shows when this device last sent and what the last check found', () {
      final at = DateTime(2026, 11, 12, 22, 5).millisecondsSinceEpoch;
      final text = resumeStatus({
        'sync_now_pushed': '$at',
        'sync_resume_debug': '2026-11-12 22:11:41.256920 older than 12 h: 2026-11-12 07:16:48.187',
      });
      expect(text, contains('上次上傳：11/12 22:05'));
      expect(text, contains('上次檢查：另一台的播放超過 12 小時（2026-11-12 07:16）'));
    });

    test('nothing sent yet', () {
      expect(resumeStatus({}), '上次上傳：尚未上傳');
    });

    test('each check result in words', () {
      String check(String why) => resumeStatus({'sync_resume_debug': '2026-11-12 22:11:41.256920 $why'}).split('\n').last;
      expect(check('this device is newer: x <= y'), '上次檢查：這台的播放較新');
      expect(check('loaded: a:1'), '上次檢查：已接續');
      expect(check('nothing from another device'), '上次檢查：另一台沒有播放紀錄');
    });
  });

  test('a play position that could not be sent is sent again', () {
    final src = File('lib/providers/sync_provider.dart').readAsStringSync();
    expect(src, contains('nowPending = true'));
    expect(src, contains('if (notifier.nowPending) unawaited(notifier.pushNowPlaying());'));
  });

  test('不受省電限制 asks Android to take the app off battery optimisation', () {
    expect(File('android/app/src/main/AndroidManifest.xml').readAsStringSync(), contains('REQUEST_IGNORE_BATTERY_OPTIMIZATIONS'));
    expect(File('lib/ui/pages/settings/sync_settings.dart').readAsStringSync(), contains('const PowerTile()'));
  });

  test('the playlist download button is in the theme colour while songs are missing', () {
    expect(File('lib/ui/pages/collection_page.dart').readAsStringSync(), contains('t.source == TrackSource.missing) ? AppTheme.accent(context)'));
  });

  test('old records naming one song two ways no longer flip it on every sync', () async {
    final db = await openDb();
    await db.upsertTracks([
      const Track(id: '/m/u.m4a', uri: '/m/u.m4a', title: 'Usseewa', artist: 'Ado', album: 'x', durationMs: 200000, source: TrackSource.local, addedAt: 1),
    ]);
    final edits = EditSync(db: db, drive: FakeDrive());
    final log = <String>[];
    edits.onApplied = (a, b, c, d) => log.add('$a→$b');
    // The other device still lists two old edits of the same song under
    // different roots: one Japanese (newer), one romaji (older).
    final theirs = [
      {
        'edits': {
          songKey('Usseewa', 'Ado'): {'ms': 200000, 't': 'うっせぇわ', 'a': 'Ado', 'al': 'x', 'at': 20, 'd': 'pc'},
          songKey('うっせぇわ', 'Ado'): {'ms': 200000, 't': 'Usseewa', 'a': 'Ado', 'al': 'x', 'at': 10, 'd': 'pc'},
        },
      },
    ];
    for (var i = 0; i < 10; i++) {
      await edits.apply(theirs, 'phone', const {});
    }
    expect((await db.track('/m/u.m4a'))!.title, 'うっせぇわ');
    expect(log, ['Usseewa→うっせぇわ']);
  });
}
