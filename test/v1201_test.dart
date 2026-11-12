import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/cover_finder.dart';
import 'package:ouoplayer/services/online/itunes.dart';
import 'package:ouoplayer/services/song_matcher.dart';

/// iTunes answering from a fixed list; counts the searches.
class FakeITunes extends ITunesSearch {
  FakeITunes(this.songs);
  final List<ITunesSong> songs;
  final queries = <String>[];

  @override
  Future<List<ITunesSong>> search(String query, {int limit = 200, String? store}) async {
    queries.add(query);
    final q = query.toLowerCase();
    return songs.where((s) => q.contains(s.title.toLowerCase()) || q.contains(s.album.toLowerCase())).toList();
  }
}

ITunesSong it(int id, String title, String album) =>
    ITunesSong(id: id, title: title, artist: 'TUYU', album: album, viewUrl: 'https://x/$id', artwork: 'https://art/$id/600x600bb.jpg');

Track song(String title, String album) =>
    Track(id: '/m/$title.m4a', uri: '/m/$title.m4a', title: title, artist: 'TUYU', album: album, source: TrackSource.download);

void main() {
  test('songs tagged with one album each get their own cover', () async {
    final itunes = FakeITunes([
      it(1, 'やっぱり雨は降るんだね', 'やっぱり雨は降るんだね - Single'),
      it(2, 'くらべられっ子', 'くらべられっ子 - Single'),
      it(3, 'あの世行きのバスに乗ってさらば。', 'あの世行きのバスに乗ってさらば。 - Single'),
    ]);
    final finder = CoverFinder(itunes, pause: Duration.zero);
    // All three carry the first one's album tag (as downloads often do).
    final hits = <String, CoverHit?>{};
    await finder.findAll([
      song('やっぱり雨は降るんだね', 'やっぱり雨は降るんだね'),
      song('くらべられっ子', 'やっぱり雨は降るんだね'),
      song('あの世行きのバスに乗ってさらば。', 'やっぱり雨は降るんだね'),
    ], (t, h) => hits[t.title] = h);
    expect(hits['やっぱり雨は降るんだね']!.song.id, 1);
    expect(hits['くらべられっ子']!.song.id, 2);
    expect(hits['あの世行きのバスに乗ってさらば。']!.song.id, 3);
    expect(hits.values.every((h) => h!.level == MatchLevel.sure), isTrue);
  });

  test('found only by its album: offered as 可能是, not ticked', () async {
    final itunes = FakeITunes([it(1, '別の曲', 'THE ALBUM')]);
    final finder = CoverFinder(itunes, pause: Duration.zero);
    final hit = await finder.find(song('未発表曲', 'THE ALBUM'));
    expect(hit?.level, MatchLevel.maybe);
  });

  test('downloads look for the official cover first, the search result\'s after', () {
    final src = File('lib/services/download_finish.dart').readAsStringSync();
    expect(src.indexOf('finder.find(named)'), lessThan(src.indexOf('squareArt(task.art)')));
  });
}
