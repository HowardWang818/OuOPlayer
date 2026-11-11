import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/services/online/ytmusic.dart';
import 'package:ouoplayer/ui/widgets/download_actions.dart';

YtMusicSong song(String id, String title, String artist, {int? ms}) => YtMusicSong(videoId: id, title: title, artist: artist, durationMs: ms);

void main() {
  group('試聽', () {
    test('a preview remembers the song page, so ♥ and 加入播放清單 download it', () {
      previewSources['https://rr1.googlevideo.com/x'] = (url: 'https://music.youtube.com/watch?v=abc', title: '群青');
      expect(previewSourceOf('https://rr1.googlevideo.com/x')!.url, 'https://music.youtube.com/watch?v=abc');
      expect(previewSourceOf('/storage/emulated/0/Music/a.mp3'), isNull);
      // Asks first (1.19.4), then downloads.
      final menu = File('lib/ui/widgets/track_tile.dart').readAsStringSync();
      expect(menu, contains('downloadPreview(context, preview, like: false)'));
      expect(menu, contains('downloadPreview(context, preview, like: true)'));
      expect(File('lib/ui/widgets/player_controls.dart').readAsStringSync(), contains('downloadPreview(context, preview, like: true)'));
      final actions = File('lib/ui/widgets/download_actions.dart').readAsStringSync();
      expect(actions, contains('下載並加入已按讚的歌曲？'));
      expect(actions, contains('下載並加入播放清單？'));
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
