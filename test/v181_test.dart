import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/missing_songs.dart';

import 'v0120_test.dart' show openDb;

Track _song(String id, String title, String artist, int ms) =>
    Track(id: id, uri: '/m/$id.m4a', title: title, artist: artist, durationMs: ms, source: TrackSource.download, addedAt: 1);

void main() {
  test('a sent song takes the place of its placeholder by the sender\'s names', () async {
    final db = await openDb();
    final list = await db.createPlaylist('Drive');
    final hole = await MissingSongs.create(db, '夜に駆ける', 'YOASOBI', durationMs: 259000);
    await db.replacePlaylistTracks(list, [hole.id]);
    // The file's own tags said 「Yoru ni Kakeru」; the sender shows 「夜に駆ける」.
    final got = _song('a', '夜に駆ける', 'YOASOBI', 261000);
    await db.upsertTracks([got]);
    await MissingSongs.fillExact(db, got);
    expect((await db.playlistTracks(list)).map((t) => t.id), ['a']);
  });

  test('songs sent before keep their playlist place when length and title or artist agree', () async {
    final db = await openDb();
    final list = await db.createPlaylist('Car');
    final hole = await MissingSongs.create(db, '夜に駆ける', 'YOASOBI', durationMs: 259000);
    final other = await MissingSongs.create(db, 'Lemon', '米津玄師', durationMs: 256000);
    await db.replacePlaylistTracks(list, [hole.id, other.id]);
    await db.upsertTracks([
      _song('a', 'Yoru ni Kakeru', 'YOASOBI', 259400), // same artist, same length
      _song('b', 'Lemon', 'Someone Else', 300000), // same title, other length: not this one
    ]);
    final filled = await MissingSongs.fillLoose(db);
    expect(filled.map((f) => f.track.id), ['a']);
    expect((await db.playlistTracks(list)).map((t) => t.id), ['a', other.id]);
  });
}
