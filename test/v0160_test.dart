import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/auto_backup.dart';
import 'package:ouoplayer/services/folder_tree.dart';
import 'package:path/path.dart' as p;

import 'v0120_test.dart' as v0120;

void main() {
  group('backup schedule', () {
    test('daily at 03:00', () {
      const s = BackupSchedule(enabled: true, frequency: BackupFrequency.daily, hour: 3);
      final now = DateTime(2026, 10, 24, 2, 0);
      expect(s.lastDue(now), DateTime(2026, 10, 23, 3));
      expect(s.nextDue(now), DateTime(2026, 10, 24, 3));
      expect(s.isDue(now, DateTime(2026, 10, 23, 4)), isFalse);
      expect(s.isDue(now, DateTime(2026, 10, 22, 4)), isTrue);
      expect(s.isDue(now, null), isTrue);
      expect(s.copyWith(enabled: false).isDue(now, null), isFalse);
    });

    test('chosen weekdays', () {
      // 2026-10-24 is a Saturday.
      const s = BackupSchedule(enabled: true, frequency: BackupFrequency.weekly, weekdays: {DateTime.monday, DateTime.thursday}, hour: 21, minute: 30);
      final now = DateTime(2026, 10, 24, 12);
      expect(s.lastDue(now), DateTime(2026, 10, 22, 21, 30));
      expect(s.nextDue(now), DateTime(2026, 10, 26, 21, 30));
    });

    test('day 31 falls on the last day of shorter months', () {
      const s = BackupSchedule(enabled: true, frequency: BackupFrequency.monthly, monthDay: 31, hour: 0);
      expect(s.nextDue(DateTime(2027, 2, 1)), DateTime(2027, 2, 28));
      expect(s.nextDue(DateTime(2026, 11, 2)), DateTime(2026, 11, 30));
      expect(s.lastDue(DateTime(2026, 11, 2)), DateTime(2026, 10, 31));
    });

    test('saved and read back', () {
      const s = BackupSchedule(enabled: true, frequency: BackupFrequency.weekly, weekdays: {1, 5}, monthDay: 9, hour: 7, minute: 15);
      final back = BackupSchedule.decode(s.encode());
      expect((back.enabled, back.frequency, back.monthDay, back.hour, back.minute), (true, BackupFrequency.weekly, 9, 7, 15));
      expect(back.weekdays, {1, 5});
      expect(BackupSchedule.decode('garbage').enabled, isFalse);
    });
  });

  test('automatic backups keep the newest 10 and never touch manual ones', () async {
    final db = await v0120.openDb();
    final dir = await Directory.systemTemp.createTemp('ouo_backup');
    addTearDown(() => dir.delete(recursive: true));
    File(p.join(dir.path, 'OuOPlayer備份_2026-01-01.json')).writeAsStringSync('{}');
    for (var i = 0; i < 12; i++) {
      await AutoBackup.run(db, dir.path, now: DateTime(2026, 10, 1 + i, 3));
    }
    final files = await AutoBackup.list(dir.path);
    expect(files.where((f) => f.automatic).length, 10);
    expect(files.where((f) => !f.automatic).length, 1);
    final names = [for (final f in files.where((f) => f.automatic)) p.basename(f.path)]..sort();
    expect(names.first, AutoBackup.fileName(DateTime(2026, 10, 3, 3)));
    expect(names.last, AutoBackup.fileName(DateTime(2026, 10, 12, 3)));
  });

  group('folder browsing', () {
    final ctx = p.Context(style: p.Style.posix);
    Track t(String id, String path, {String? art}) => Track(id: id, uri: path, title: id, art: art, source: TrackSource.local);
    final tree = FolderTree([
      t('b', '/m/Music/b.mp3'),
      t('a', '/m/Music/a.mp3'),
      t('x', '/m/Music/Anime/x.mp3', art: '/c/x.jpg'),
      t('y', '/m/Music/Anime/OP/y.mp3'),
      t('z', '/m/Music/OuOPlayer/z.m4a'),
      t('o', '/elsewhere/o.mp3'),
      const Track(id: 'u', uri: 'https://x/u.mp3', title: 'u', source: TrackSource.url),
    ], context: ctx);

    test('starting folders leave out ones inside another', () {
      expect(tree.roots(['/m/Music', '/m/Music/OuOPlayer', '/m/Podcasts']), ['/m/Music', '/m/Podcasts']);
    });

    test('sub-folders first, then the songs right here', () {
      final l = tree.list('/m/Music');
      expect([for (final f in l.folders) (f.name, f.count, f.art)], [('Anime', 2, '/c/x.jpg'), ('OuOPlayer', 1, null)]);
      expect([for (final s in l.songs) s.id], ['a', 'b']);
      expect(tree.countIn('/m/Music'), 5);
      expect([for (final s in tree.everything('/m/Music/Anime')) s.id], ['x', 'y']);
    });
  });
}
