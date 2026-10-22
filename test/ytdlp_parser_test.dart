import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/services/library_scanner.dart';
import 'package:ouoplayer/services/podcast_service.dart';
import 'package:ouoplayer/services/ytdlp/ytdlp_downloader.dart';

void main() {
  test('parses progress, playlist item and finished file lines', () {
    final parser = YtDlpLineParser();
    expect(parser.parse('[download] Downloading item 2 of 5'), isA<YtDlpLog>());

    final progress = parser.parse('OUOPROG  42.5%|00:13') as YtDlpProgress;
    expect(progress.percent, 42.5);
    expect(progress.eta, '00:13');
    expect(progress.item, 2);
    expect(progress.itemCount, 5);

    final done = parser.parse(r'OUOFILE D:\Music\OuOPlayer\歌曲.mp3') as YtDlpFileDone;
    expect(done.path, r'D:\Music\OuOPlayer\歌曲.mp3');

    expect(parser.parse('   '), isNull);
  });

  test('builds yt-dlp arguments for audio extraction', () {
    const opts = YtDlpOptions(url: 'https://example.com/v', format: 'm4a', playlist: false, outDir: 'out');
    expect(opts.args, containsAllInOrder(['-x', '--audio-format', 'm4a']));
    expect(opts.args, contains('--no-playlist'));
    expect(opts.args, isNot(contains('https://example.com/v')));

    const best = YtDlpOptions(url: 'u', format: 'best', playlist: true, outDir: 'out');
    expect(best.args, isNot(contains('--audio-format')));
    expect(best.args, contains('--yes-playlist'));
  });

  test('repairs UTF-8 tags that were decoded as Latin-1', () {
    final garbled = latin1.decode(utf8.encode('冰島 Ace'));
    expect(fixTagText(garbled), '冰島 Ace');
    expect(fixTagText('Café'), 'Café'); // genuine Latin-1 stays as is
    expect(fixTagText('冰島'), '冰島');
    expect(fixTagText('Plain\u0000'), 'Plain');
  });

  test('parses podcast durations', () {
    expect(PodcastService.parseDuration('1:02:03'), 3723000);
    expect(PodcastService.parseDuration('90'), 90000);
    expect(PodcastService.parseDuration(null), isNull);
  });
}
