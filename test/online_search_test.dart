import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/online/itunes.dart';

void main() {
  test('parses iTunes songs and builds links', () {
    // Trimmed real response shape from itunes.apple.com/search?entity=song.
    final body = jsonEncode({
      'resultCount': 2,
      'results': [
        {
          'wrapperType': 'track',
          'trackId': 1490256995,
          'trackName': '夜に駆ける',
          'artistName': 'YOASOBI',
          'collectionName': '夜に駆ける - Single',
          'artworkUrl100': 'https://is1-ssl.mzstatic.com/image/thumb/a.jpg/100x100bb.jpg',
          'previewUrl': 'https://audio-ssl.itunes.apple.com/p.m4a',
          'trackTimeMillis': 261013,
          'trackViewUrl': 'https://music.apple.com/tw/album/x/1490256978?i=1490256995&uo=4',
        },
        {'wrapperType': 'collection', 'collectionId': 1},
      ],
    });
    final songs = ITunesSearch.parse(body);
    expect(songs, hasLength(1));
    final s = songs.single;
    expect(s.title, '夜に駆ける');
    expect(s.artwork, endsWith('600x600bb.jpg'));
    expect(s.songLinkUrl, 'https://song.link/i/1490256995');
    expect(s.iTunesStoreUrl, endsWith('&app=itunes'));
    expect(s.moraUrl, contains('keyWord=%E5%A4%9C'));
    final preview = s.previewTrack!;
    expect(preview.uri, 'https://audio-ssl.itunes.apple.com/p.m4a');
    expect(preview.artist, 'YOASOBI');
    // Previews are tagged so they stay out of history and the library.
    expect(preview.source, TrackSource.preview);
  });

  test('song without preview has no preview track', () {
    final s = ITunesSong.fromJson({'trackId': 1, 'trackName': 'a', 'artistName': 'b', 'trackViewUrl': 'https://x'});
    expect(s.previewTrack, isNull);
  });
}
