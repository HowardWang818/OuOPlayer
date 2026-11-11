import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/services/download_service.dart';
import 'package:ouoplayer/services/online/ytmusic.dart';
import 'package:ouoplayer/ui/widgets/download_actions.dart';

YtMusicSong song(String id, String title, String artist, {int? ms}) => YtMusicSong(videoId: id, title: title, artist: artist, durationMs: ms);

void main() {
  group('試聽', () {
    test('a looked-up address is kept until YouTube says it expires', () {
      final now = DateTime(2026, 11, 11, 20);
      final expire = now.add(const Duration(hours: 6)).millisecondsSinceEpoch ~/ 1000;
      final at = DownloadService.streamExpiry('https://rr1.googlevideo.com/videoplayback?expire=$expire&id=x', now);
      expect(at, DateTime.fromMillisecondsSinceEpoch(expire * 1000).subtract(const Duration(minutes: 10)));
      expect(DownloadService.streamExpiry('https://example.com/a.m4a', now), now.add(const Duration(hours: 4)));
    });

    test('a preview remembers the song page, so ♥ and 加入播放清單 download it', () {
      previewSources['https://rr1.googlevideo.com/x'] = (url: 'https://music.youtube.com/watch?v=abc', title: '群青');
      expect(previewSourceOf('https://rr1.googlevideo.com/x')!.url, 'https://music.youtube.com/watch?v=abc');
      expect(previewSourceOf('/storage/emulated/0/Music/a.mp3'), isNull);
      final menu = File('lib/ui/widgets/track_tile.dart').readAsStringSync();
      expect(menu, contains('askPlaylist: true'));
      expect(menu, contains('like: true'));
      expect(File('lib/ui/widgets/player_controls.dart').readAsStringSync(), contains('like: true'));
    });
  });

  group('缺少的歌曲只自動下載確定的', () {
    test('same song, same artist, close length: downloaded', () {
      final results = [
        song('cover', '群青 (Cover)', 'Someone', ms: 248000),
        song('ok', '群青', 'YOASOBI', ms: 249000),
      ];
      expect(sureMatch('群青', 'YOASOBI', 248000, results)?.videoId, 'ok');
    });

    test('another artist singing it is not sure', () {
      expect(sureMatch('propose', 'natori', 200000, [song('x', 'propose', '9Lana', ms: 200000)]), isNull);
    });

    test('a much longer take (live, extended) is not sure', () {
      expect(sureMatch('群青', 'YOASOBI', 248000, [song('live', '群青', 'YOASOBI', ms: 270000)]), isNull);
    });

    test('nothing found: nothing to download', () {
      expect(sureMatch('群青', 'YOASOBI', 248000, const []), isNull);
    });

    test('unsure songs are offered to pick by hand', () {
      final page = File('lib/ui/pages/missing_songs_page.dart').readAsStringSync();
      expect(page, contains('sureMatch('));
      expect(page, contains("child: const Text('選擇')"));
    });
  });
}
