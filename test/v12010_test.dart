// 1.20.10: 加入播放清單 is one ticking sheet everywhere; deleting files can
// take the songs out of playlists and likes too.
import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/missing_songs.dart';
import 'package:ouoplayer/ui/widgets/playlist_picker.dart';

import 'v0120_test.dart' show openDb;

Track _t(String id) => Track(id: id, uri: id, title: id, artist: 'A', durationMs: 200000, source: TrackSource.download, addedAt: 1);

void main() {
  group('ticks', () {
    test('all songs in it → ticked, none → empty, some → partly', () {
      expect(tickFor(3, 3), isTrue);
      expect(tickFor(0, 3), isFalse);
      expect(tickFor(1, 3), isNull);
      expect(tickFor(1, 1), isTrue);
    });

    test('tapping: ticked ↔ empty; partly → ticked → empty → partly', () {
      expect(nextTick(true, true), isFalse);
      expect(nextTick(false, false), isTrue);
      expect(nextTick(null, null), isTrue);
      expect(nextTick(true, null), isFalse);
      expect(nextTick(false, null), isNull);
    });

    test('完成: newly ticked get the songs, newly emptied lose them, partly stays', () {
      final before = {1: true, 2: false, 3: null, 4: null, 5: false};
      final after = {1: false, 2: true, 3: null, 4: true, 5: false, 6: true};
      final c = playlistChanges(before, after);
      expect(c.add, {2, 4, 6});
      expect(c.remove, {1});
    });
  });

  group('filesDeleted', () {
    Future<(dynamic, int, Track, Track)> setUpLib() async {
      final db = await openDb();
      final a = _t('a'), b = _t('b');
      await db.upsertTracks([a, b]);
      final list = await db.createPlaylist('通勤');
      await db.addToPlaylist(list, [a, b]);
      await db.setFavorite(a, true);
      return (db, list, a, b);
    }

    test('taken out of playlists and likes too: nothing greyed is left', () async {
      final (db, list, a, _) = await setUpLib();
      await MissingSongs.filesDeleted(db, [a], fromLists: true);
      expect([for (final t in await db.playlistTracks(list)) t.id], ['b']);
      expect((await db.db.query('playlist_tracks')).length, 1);
      expect(await db.db.query('favorites'), isEmpty);
      expect(await db.track('a'), isNull);
    });

    test('kept: playlist and like keep a greyed place', () async {
      final (db, list, a, _) = await setUpLib();
      await MissingSongs.filesDeleted(db, [a], fromLists: false);
      final rows = await db.db.query('playlist_tracks', where: 'playlist_id = ?', whereArgs: [list], orderBy: 'position');
      expect(rows.length, 2);
      expect(rows.first['track_id'], isNot('a'));
      expect((await db.db.query('favorites')).length, 1);
      expect(await db.track('a'), isNull);
    });
  });
}
