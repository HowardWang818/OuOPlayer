import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/services/download_service.dart';
import 'package:ouoplayer/ui/pages/search_page.dart';

void main() {
  group('本機播放器，不是串流', () {
    test('online search never names YouTube Music on screen', () {
      final src = File('lib/ui/pages/search_page.dart').readAsStringSync();
      final shown = RegExp(r"'([^'\n]*)'").allMatches(src).map((m) => m.group(1)!);
      expect(shown.where((t) => t.contains('YouTube Music')), isEmpty);
      expect(src, contains("title: '線上搜尋'"));
    });

    test('results say songs are downloaded to play and previews are 30 seconds', () {
      expect(onlineNote, '下載後才能播放，試聽僅 30 秒');
      final src = File('lib/ui/pages/search_page.dart').readAsStringSync();
      expect(src, contains('（試聽）'));
      expect(src, contains("toast(context, '試聽 30 秒')"));
    });

    test('the first visit explains OuOPlayer is a local player, once', () {
      expect(localPlayerTitle, 'OuOPlayer 是本機播放器');
      expect(localPlayerText, contains('下載後即可離線播放'));
      expect(localPlayerKey, isNotEmpty);
    });
  });

  group('下載進度在封面上', () {
    test('song lists no longer mark downloaded songs', () {
      expect(File('lib/ui/widgets/track_tile.dart').readAsStringSync(), isNot(contains('arrow_circle_down')));
    });

    test('online results, the downloads list and missing songs show it', () {
      for (final f in ['lib/ui/pages/search_page.dart', 'lib/ui/pages/downloads_page.dart', 'lib/ui/pages/missing_songs_page.dart']) {
        expect(File(f).readAsStringSync(), contains('CoverProgress('), reason: f);
      }
    });

    test('a download keeps the cover it was started with', () {
      final t = DownloadTask(id: '1', url: 'https://music.youtube.com/watch?v=a', kind: DownloadKind.ytdlp, format: 'm4a')..art = 'https://lh3/a';
      expect(t.art, 'https://lh3/a');
    });
  });
}
