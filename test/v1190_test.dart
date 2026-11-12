import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/services/download_target.dart';
import 'package:ouoplayer/services/online/ytmusic.dart';
import 'package:ouoplayer/ui/widgets/download_actions.dart';

/// One song row the way YouTube Music's search answers.
Map<String, dynamic> row(String id, String title, List<String> info, {String? thumb}) => {
      'musicResponsiveListItemRenderer': {
        'playlistItemData': {'videoId': id},
        'thumbnail': {
          'musicThumbnailRenderer': {
            'thumbnail': {
              'thumbnails': [
                {'url': thumb ?? 'https://lh3.googleusercontent.com/abc=w60-h60-l90-rj'},
                {'url': thumb ?? 'https://lh3.googleusercontent.com/abc=w120-h120-l90-rj'},
              ],
            },
          },
        },
        'flexColumns': [
          {
            'musicResponsiveListItemFlexColumnRenderer': {
              'text': {
                'runs': [
                  {'text': title},
                ],
              },
            },
          },
          {
            'musicResponsiveListItemFlexColumnRenderer': {
              'text': {'runs': [for (final t in info) {'text': t}]},
            },
          },
        ],
      },
    };

Map<String, dynamic> response(List<Map<String, dynamic>> rows) => {
      'contents': {
        'tabbedSearchResultsRenderer': {
          'tabs': [
            {
              'tabRenderer': {
                'content': {
                  'sectionListRenderer': {
                    'contents': [
                      {
                        'musicShelfRenderer': {'contents': rows},
                      },
                    ],
                  },
                },
              },
            },
          ],
        },
      },
    };

void main() {
  group('YouTube Music 搜尋', () {
    test('title, artist, album, length and a large cover', () {
      final songs = YtMusicSearch.parse(response([
        row('x8VYWazR5mE', '夜に駆ける', ['YOASOBI', ' • ', 'THE BOOK', ' • ', '4:21']),
      ]));
      final s = songs.single;
      expect(s.videoId, 'x8VYWazR5mE');
      expect(s.title, '夜に駆ける');
      expect(s.artist, 'YOASOBI');
      expect(s.album, 'THE BOOK');
      expect(s.durationMs, 261000);
      expect(s.artwork, 'https://lh3.googleusercontent.com/abc=w544-h544-l90-rj');
      expect(s.url, 'https://music.youtube.com/watch?v=x8VYWazR5mE');
    });

    test('several artists, hour-long tracks, no album', () {
      final songs = YtMusicSearch.parse(response([
        row('a', 'Hip Hop BGM', ['Lo-Fi Japan', '、', 'ChillHop Cafe', ' 和 ', 'Lofi Chillhop', ' • ', 'Lofi Chill Music', ' • ', '1:23']),
        row('b', '3 Hours of Lofi', ['Lumosound', ' • ', '3:03:37']),
      ]));
      expect(songs[0].artist, 'Lo-Fi Japan、ChillHop Cafe 和 Lofi Chillhop');
      expect(songs[0].durationMs, 83000);
      expect(songs[1].album, isNull);
      expect(songs[1].durationMs, (3 * 3600 + 3 * 60 + 37) * 1000);
    });

    test('rows without a video are skipped; an empty answer is no songs', () {
      final noVideo = row('x', 'Artist page', ['Artist']);
      (noVideo['musicResponsiveListItemRenderer'] as Map).remove('playlistItemData');
      expect(YtMusicSearch.parse(response([noVideo])), isEmpty);
      expect(YtMusicSearch.parse({}), isEmpty);
    });
  });

  group('下載至播放清單', () {
    test('the choice is kept for an hour', () {
      final at = DateTime(2026, 11, 11, 20);
      final t = DownloadTarget(playlistId: 3, name: 'BGM', at: at);
      expect(t.freshAt(at.add(const Duration(minutes: 59))), isTrue);
      expect(t.freshAt(at.add(const Duration(hours: 1))), isFalse);
    });

    test('saved and read back, including 僅加入音樂庫', () {
      final at = DateTime(2026, 11, 11, 20);
      final back = DownloadTarget.decode(DownloadTarget(playlistId: 3, name: 'BGM', at: at).encode())!;
      expect((back.playlistId, back.name, back.at), (3, 'BGM', at));
      final none = DownloadTarget.decode(DownloadTarget(at: at).encode())!;
      expect(none.playlistId, isNull);
      expect(DownloadTarget.decode('nonsense'), isNull);
      expect(DownloadTarget.decode(null), isNull);
    });
  });

  group('拿掉的功能', () {
    test('no YouTube key, no iTunes song search, no link lookups', () {
      expect(File('lib/ui/pages/youtube_key_guide_page.dart').existsSync(), isFalse);
      expect(File('lib/services/online/youtube_link.dart').existsSync(), isFalse);
      final search = File('lib/ui/pages/search_page.dart').readAsStringSync();
      expect(search, isNot(contains('ITunesSong')));
      expect(search, contains('onlineSongsProvider'));
      final missing = File('lib/ui/pages/missing_songs_page.dart').readAsStringSync();
      expect(missing, isNot(contains('youtubeApiKey')));
      expect(missing, contains('全部下載'));
      expect(File('lib/providers/providers.dart').readAsStringSync(), isNot(contains('youtubeApiKey')));
    });

    test('the download terms are shown in the app and the READMEs', () {
      expect(downloadTerms, contains('法律責任'));
      // Shown once, then only on 下載 and in its settings.
      expect(File('lib/ui/pages/help_page.dart').readAsStringSync(), isNot(contains('downloadTerms')));
      expect(File('lib/ui/pages/downloads_page.dart').readAsStringSync(), contains('downloadTerms'));
      expect(File('lib/ui/pages/settings/download_settings.dart').readAsStringSync(), contains('downloadTerms'));
      expect(File('README.md').readAsStringSync(), contains('法律責任'));
    });
  });
}
