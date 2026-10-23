import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/services/online/itunes.dart';
import 'package:ouoplayer/services/online/youtube_link.dart';

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
  });

  test('song without preview has no preview track', () {
    final s = ITunesSong.fromJson({'trackId': 1, 'trackName': 'a', 'artistName': 'b', 'trackViewUrl': 'https://x'});
    expect(s.previewTrack, isNull);
  });

  test('parses the first YouTube video', () {
    final v = YouTubeLinkFinder.parse({
      'items': [
        {'id': {'kind': 'youtube#channel', 'channelId': 'c'}},
        {
          'id': {'kind': 'youtube#video', 'videoId': 'x8VYWazR5mE'},
          'snippet': {'title': 'YOASOBI「夜に駆ける」', 'channelTitle': 'Ayase / YOASOBI'},
        },
      ],
    })!;
    expect(v.url, 'https://www.youtube.com/watch?v=x8VYWazR5mE');
    expect(v.channel, 'Ayase / YOASOBI');
    expect(YouTubeLinkFinder.parse({'items': []}), isNull);
  });

  test('explains Google API errors in Chinese', () {
    Map<String, dynamic> err(String reason, [String message = '']) => {
          'error': {
            'message': message,
            'errors': [
              {'reason': reason},
            ],
          },
        };
    expect(YouTubeLinkFinder.explainError(err('quotaExceeded'), null), contains('額度'));
    expect(YouTubeLinkFinder.explainError(err('badRequest', 'API key not valid. Please pass a valid API key.'), null), contains('金鑰無效'));
    expect(YouTubeLinkFinder.explainError(err('accessNotConfigured'), null), contains('尚未啟用'));
    expect(YouTubeLinkFinder.explainError(null, 'timeout'), contains('網路'));
  });
}
