import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/cover_finder.dart';
import 'package:ouoplayer/services/online/itunes.dart';

ITunesSong _s(String title, String artist, {String album = '', int sec = 200}) => ITunesSong(
    id: '$title$artist'.hashCode, title: title, artist: artist, album: album, viewUrl: '', durationMs: sec * 1000, artwork: 'https://a/$title/600x600bb.jpg');

/// iTunes as the stores answer: Taiwan in romaji, Japan in Japanese.
class FakeITunes extends ITunesSearch {
  FakeITunes(this.byStore);
  final Map<String, List<ITunesSong>> byStore;
  final asked = <String>[];
  @override
  Future<List<ITunesSong>> search(String query, {int limit = 200, String? store}) async {
    asked.add('${store ?? ITunesSearch.country}:$query');
    return byStore[store ?? ITunesSearch.country] ?? const [];
  }
}

void main() {
  const t = Track(id: 'a', uri: '/m/a.m4a', title: '醜形恐怖症', artist: 'なるみや', album: '醜形恐怖症', durationMs: 200000, source: TrackSource.download);

  test('a Japanese song is found in the Japanese store when Taiwan answers in romaji', () async {
    final it = FakeITunes({
      ITunesSearch.country: [_s('Shukei Kyoufushou', 'Narumiya')],
      'JP': [_s('醜形恐怖症', 'なるみや')],
    });
    final hit = await CoverFinder(it, pause: Duration.zero).find(t);
    expect(hit?.song.title, '醜形恐怖症');
    // Asked for at 1200×1200.
    expect(hit!.url, contains('1200x1200bb'));
  });

  test('not found by title: the album cover is used', () async {
    final it = FakeITunes({'JP': [_s('別の曲', 'なるみや', album: '醜形恐怖症 - Single')]});
    final hit = await CoverFinder(it, pause: Duration.zero).find(const Track(
        id: 'b', uri: '/m/b.m4a', title: 'Intro', artist: 'なるみや', album: '醜形恐怖症', durationMs: 90000, source: TrackSource.download));
    expect(hit?.song.title, '別の曲');
  });
}
