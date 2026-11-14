// 1.20.9: songs passed on the way while deleting several from the queue
// were logged as plays (41 plays of 0 s in one second); 接續播放 carries the
// play on in the same entry.
import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/db/database.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/sync2/now_playing.dart';

import 'v0120_test.dart' show openDb;

Track _t(String id) => Track(id: id, uri: id, title: id, artist: 'A', durationMs: 200000, source: TrackSource.download, addedAt: 1);

void main() {
  group('skippedThrough', () {
    test('three or more 0 s plays, each within a second: passed on the way', () {
      final ids = AppDatabase.skippedThrough([(1, 1000, 0), (2, 1010, 0), (3, 1300, 0), (4, 1900, 0)]);
      expect(ids, {1, 2, 3, 4});
    });

    test('two quick skips, or 0 s plays far apart: real', () {
      expect(AppDatabase.skippedThrough([(1, 1000, 0), (2, 1500, 0)]), isEmpty);
      expect(AppDatabase.skippedThrough([(1, 1000, 0), (2, 5000, 0), (3, 9000, 0)]), isEmpty);
    });

    test('a play that was heard breaks nothing and stays', () {
      final ids = AppDatabase.skippedThrough([(1, 1000, 0), (2, 1010, 45000), (3, 1020, 0), (4, 1030, 0)]);
      expect(ids, {1, 3, 4});
    });
  });

  test('dropSkippedThrough: the plays, their play counts and recently played go', () async {
    final db = await openDb();
    final a = _t('a'), b = _t('b'), c = _t('c');
    await db.upsertTracks([a, b, c]);
    // c was really listened to once.
    await db.addHistory(c);
    final real = await db.startListening(c, DateTime.fromMillisecondsSinceEpoch(500));
    await db.updateListening(real, const Duration(seconds: 90));
    // Then a and b, over and over within a second, 0 s each.
    for (var i = 0; i < 6; i++) {
      final t = i.isEven ? a : b;
      await db.db.insert('history', {'track_id': t.id, 'played_at': 100000 + i * 10});
      await db.db.rawInsert('INSERT OR IGNORE INTO plays(track_id, count, last_played) VALUES(?, 0, ?)', [t.id, 100000]);
      await db.db.rawUpdate('UPDATE plays SET count = count + 1 WHERE track_id = ?', [t.id]);
      await db.startListening(t, DateTime.fromMillisecondsSinceEpoch(100000 + i * 10));
    }
    expect((await db.playCounts())['a'], 3);
    expect(await AppDatabase.dropSkippedThrough(db.db), 6);
    final left = await db.db.query('listening_log');
    expect([for (final r in left) r['track_id']], ['c']);
    final counts = await db.playCounts();
    expect(counts['a'], isNull);
    expect(counts['b'], isNull);
    expect(counts['c'], 1);
    expect((await db.db.query('history')).length, 1);
  });

  group('continueListening', () {
    test('no entry for that play here yet: one is made with its start, new', () async {
      final db = await openDb();
      final a = _t('a');
      await db.upsertTracks([a]);
      final (id, heard, isNew) = await db.continueListening(a, 7000, 30000);
      expect(isNew, isTrue);
      expect(heard, 30000);
      final row = (await db.db.query('listening_log', where: 'id = ?', whereArgs: [id])).single;
      expect(row['played_at'], 7000);
      expect(row['listened_ms'], 30000);
    });

    test('the entry sent over by sync: used and made this device\'s own', () async {
      final db = await openDb();
      final a = _t('a');
      await db.upsertTracks([a]);
      await db.db.insert('listening_log',
          {'track_id': 'a', 'played_at': 7000, 'listened_ms': 20000, 'source': 'download', 'origin': 'phone', 'remote_id': 'phone:3'});
      final (id, heard, isNew) = await db.continueListening(a, 7000, 30000);
      expect(isNew, isFalse);
      expect(heard, 30000);
      final rows = await db.db.query('listening_log');
      expect(rows.length, 1);
      expect(rows.single['id'], id);
      expect(rows.single['origin'], isNull);
      expect(rows.single['remote_id'], isNull);
    });

    test('coming back to the device it began on: its own entry, the longer time', () async {
      final db = await openDb();
      final a = _t('a');
      await db.upsertTracks([a]);
      final own = await db.startListening(a, DateTime.fromMillisecondsSinceEpoch(7000));
      await db.updateListening(own, const Duration(seconds: 50));
      final (id, heard, isNew) = await db.continueListening(a, 7000, 20000);
      expect((id, heard, isNew), (own, 50000, false));
    });
  });

  test('NowPlaying carries the play: when it began and how long it was heard', () {
    const n = NowPlaying(device: 'd', deviceName: '手機', at: 1, songs: [{'t': 'a', 'a': 'A'}], index: 0, positionMs: 5000, began: 7000, heardMs: 30000);
    final back = NowPlaying.fromJson(n.toJson())!;
    expect(back.began, 7000);
    expect(back.heardMs, 30000);
    // From a version before 1.20.9: nothing to carry on.
    final old = NowPlaying.fromJson({'device': 'd', 'at': 1, 'songs': [{'t': 'a'}]})!;
    expect(old.began, isNull);
  });
}
