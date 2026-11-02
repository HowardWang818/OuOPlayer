import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/db/database.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/backup.dart';
import 'package:ouoplayer/services/library_scanner.dart';

import 'sync2_test.dart' show Device, FakeDrive;
import 'v0120_test.dart' show openDb;

/// A play as the app records it: a play count and a listening log entry.
Future<void> _play(AppDatabase db, Track t, int day) async {
  await db.addHistory(t);
  final id = await db.startListening(t, DateTime(2026, 10, day));
  await db.updateListening(id, const Duration(seconds: 120));
}

Future<int> _count(AppDatabase db, Track t) async => (await db.playCounts())[t.id] ?? 0;

/// A backup file from before v1.14.6: its plays don't say where they came from.
Map<String, Object?> _old(Map<String, Object?> b) => {
      ...b,
      'listening': [
        for (final r in (b['listening'] as List).cast<Map>())
          {
            for (final e in r.entries)
              if (e.key != 'origin' && e.key != 'remote_id') e.key: e.value,
          },
      ],
    };

void main() {
  late Directory tmp;
  late FakeDrive drive;
  late Device phone, pc;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ouo_1146');
    drive = FakeDrive();
    phone = await Device.make('phone', drive);
    pc = await Device.make('pc', drive);
  });

  Future<void> settle(List<Device> devices) async {
    for (var i = 0; i < 3; i++) {
      for (final d in devices) {
        await d.sync();
      }
    }
  }

  for (final old in [true, false]) {
    test('a reinstall and four restores count every play once (${old ? 'older' : 'new'} backup)', () async {
      final a = await phone.song('Bunny Girl');
      final pcA = await pc.song('Bunny Girl');
      await _play(phone.db, a, 1);
      await _play(phone.db, a, 2);
      for (final day in [3, 4, 5, 6, 7, 8]) {
        await _play(pc.db, pcA, day);
      }
      await settle([phone, pc]);
      expect(await _count(phone.db, a), 8);
      expect(await _count(pc.db, pcA), 8);

      // The phone is reinstalled: a new device id, the same song file.
      var b = jsonDecode(jsonEncode(await buildBackup(phone.db, lyricsDir: tmp))) as Map<String, Object?>;
      if (old) b = _old(b);
      final again = await Device.make('phone2', drive);
      await again.db.upsertTracks([a]);
      for (var i = 0; i < 4; i++) {
        await restoreBackup(again.db, LibraryScanner(again.db), b, coverDir: tmp, lyricsDir: tmp);
        await settle([again, pc]);
      }
      await settle([phone, again, pc]);
      expect(await _count(pc.db, pcA), 8);
      expect(await _count(again.db, a), 8);
      expect(await _count(phone.db, a), 8);
      expect((await pc.db.listening(DateTime(2026), DateTime(2027))).length, 8);
    });
  }

  test('the upgrade drops plays that came more than once, with their counts', () async {
    final db = await openDb();
    final a = Track(id: '/m/a', uri: '/m/a', title: 'a', artist: 'A', durationMs: 200000, source: TrackSource.local);
    final b = Track(id: '/m/b', uri: '/m/b', title: 'b', artist: 'A', durationMs: 200000, source: TrackSource.local);
    await db.upsertTracks([a, b]);
    await _play(db, a, 1);
    // The same play sent back three times, and once under another name.
    for (final (i, t) in [(1, a), (2, a), (3, a), (4, b)]) {
      await db.db.insert('listening_log', {
        'track_id': t.id,
        'played_at': DateTime(2026, 10, 1).millisecondsSinceEpoch,
        'listened_ms': 120000,
        'source': TrackSource.local,
        'origin': 'phone2',
        'remote_id': 'phone2:$i',
      });
      await db.db.rawInsert('INSERT OR IGNORE INTO plays(track_id, count, last_played) VALUES(?, 0, 0)', [t.id]);
      await db.db.rawUpdate('UPDATE plays SET count = count + 1 WHERE track_id = ?', [t.id]);
    }
    await _play(db, a, 2);
    expect(await _count(db, a), 5);
    expect(await AppDatabase.dropRepeatedPlays(db.db), 4);
    expect(await _count(db, a), 2);
    expect(await _count(db, b), 0);
    final log = await db.db.query('listening_log');
    expect(log.length, 2);
    // This device's own entry is the one kept.
    expect(log.every((r) => r['origin'] == null), isTrue);
  });

  test('a backup says where each play came from', () async {
    final a = await phone.song('a');
    final pcA = await pc.song('a');
    await _play(pc.db, pcA, 1);
    await settle([phone, pc]);
    final b = await buildBackup(phone.db, lyricsDir: tmp);
    final entry = (b['listening'] as List).cast<Map>().single;
    expect(entry['origin'], 'pc');
    final fresh = await openDb();
    await fresh.upsertTracks([a]);
    await restoreBackup(fresh, LibraryScanner(fresh), _old(b), coverDir: tmp, lyricsDir: tmp);
    expect((await fresh.db.query('listening_log')).single['origin'], restoredOrigin);
  });
}
