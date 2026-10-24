import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/artists.dart';
import 'package:ouoplayer/services/song_matcher.dart';

import 'v0120_test.dart' as v0120;

Track song(String id, String title, String artist) =>
    Track(id: id, uri: id, title: title, artist: artist, source: TrackSource.download);

void main() {
  tearDown(() => ArtistRenames.set(const {}));

  test('renaming: chains follow, naming back drops the entry', () {
    var t = ArtistRenames.renamed(const {}, 'Ayase', 'あやせ');
    expect(t, {'Ayase': 'あやせ'});
    t = ArtistRenames.renamed(t, 'あやせ', 'AYASE!');
    expect(t, {'Ayase': 'AYASE!'});
    expect(ArtistRenames.renamed(t, 'AYASE!', 'Ayase'), isEmpty);
    expect(ArtistRenames.restored({'A': 'X', 'B': 'X', 'C': 'Y'}, 'X'), {'C': 'Y'});
  });

  test('a renamed artist is listed, grouped and matched under the new name', () async {
    ArtistRenames.set({'Ayase': 'あやせ', '李榮浩': 'Ronghao'});
    final dir = ArtistDirectory(const []);
    expect(dir.primary('Ayase, 柊キライ'), 'あやせ');
    expect(dir.primary('Li Ronghao'), 'Ronghao');
    expect(ArtistRenames.originals('あやせ'), ['Ayase']);
    expect(SongMatcher.compare(SongKey('ラブカ?', 'Ayase'), SongKey('ラブカ?', 'あやせ')).level, MatchLevel.sure);

    final db = await v0120.openDb();
    for (final t in [song('1', 'a', 'Ayase'), song('2', 'b', 'Li Ronghao'), song('3', 'c', '李荣浩')]) {
      await db.db.insert('tracks', t.toMap());
    }
    final names = {for (final a in await db.artists()) a.name: a.count};
    expect(names, {'あやせ': 1, 'Ronghao': 2});
    expect((await db.artistTracks('Ronghao')).length, 2);
  });

  test('renaming onto another artist merges them', () async {
    ArtistRenames.set({'Ayase': 'YOASOBI'});
    final db = await v0120.openDb();
    for (final t in [song('1', 'a', 'Ayase'), song('2', 'b', 'YOASOBI')]) {
      await db.db.insert('tracks', t.toMap());
    }
    final artists = await db.artists();
    expect([for (final a in artists) (a.name, a.count)], [('YOASOBI', 2)]);
  });
}
