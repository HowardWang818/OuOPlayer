import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/services/download_service.dart';
import 'package:ouoplayer/services/online/ytmusic.dart';

YtMusicSong s(String title, String artist, int ms) => YtMusicSong(videoId: title, title: title, artist: artist, durationMs: ms);

void main() {
  group('全部下載：找對版本', () {
    test('Japanese names are searched in Japanese, others as before', () {
      expect(YtMusicSearch.localeFor('知らないままで ロクデナシ'), 'ja');
      expect(YtMusicSearch.localeFor('群青 YOASOBI'), 'zh-TW');
      expect(YtMusicSearch.localeFor('李白 李榮浩'), 'zh-TW');
    });

    // What YT Music returned (2026-11-13) for 可愛いあの子が気にゐらない / なるみや.
    final kawaiiJa = [
      s('可愛いあの子が気にゐらない', 'なるみや', 199000),
      s('可愛いあの子が気にゐらない -2Key(原曲歌手:なるみや)', '歌っちゃ王', 197000),
      s('可愛いあの子が気にゐらない (原曲歌手:なるみや)', '歌っちゃ王', 197000),
    ];
    final kawaiiTw = [
      s('可愛いあの子が気にゐらない - Kawaii Anokoga Kiniiranai', 'Narumiya', 199000),
      s('可愛いあの子が気にゐらない -2Key(原曲歌手:なるみや)', '歌っちゃ王', 197000),
      s('可愛いあの子が気にゐらない (原曲歌手:なるみや)', '歌っちゃ王', 197000),
    ];

    test('the original is sure; karaoke naming the artist in its title never is', () {
      expect(sureMatch('可愛いあの子が気にゐらない', 'なるみや', 196879, kawaiiJa)?.artist, 'なるみや');
      expect(sureMatch('可愛いあの子が気にゐらない', 'なるみや', 196879, kawaiiTw), isNull);
    });

    test('covers, karaoke and other takes are left to pick by hand', () {
      expect(
          sureMatch('IRIS OUT', '米津玄師', 152000, [
            s('IRIS OUT (Russian Cover)', 'TRISHA', 149000),
            s('IRIS OUT(ガイド無しカラオケ) -5Key[原曲歌手:米津玄師]', '歌っちゃ王', 152000),
          ]),
          isNull);
      expect(sureMatch('青のすみか', 'キタニタツヤ', 197000, [s('青のすみか (Acoustic ver.)', 'キタニタツヤ', 204000), s('青のすみか', 'keiko', 192000)]),
          isNull);
      expect(
          sureMatch('青と夏', 'Mrs. GREEN APPLE', 270513, [
            s('青と夏 +3Key(原曲歌手:Mrs. GREEN APPLE)[ガイド無しカラオケ]', '歌っちゃ王', 271000),
            s('青と夏', 'Mrs. GREEN APPLE', 271000),
          ])?.title,
          '青と夏');
      expect(
          sureMatch('今はいいんだよ。', 'MIMI', 147085, [
            s('今はいいんだよ。 (Cover)', 'Kotoha', 148000),
            s('今はいいんだよ。 [Cover]（feat. saewool）', 'MIMI', 148000),
            s('今はいいんだよ。（feat. 可不）', 'MIMI', 148000),
          ])?.title,
          '今はいいんだよ。（feat. 可不）');
    });

    test('a take asked for by name is still found', () {
      expect(sureMatch('青のすみか (Acoustic ver.)', 'キタニタツヤ', 204000, [s('青のすみか (Acoustic ver.)', 'キタニタツヤ', 204000)]), isNotNull);
    });

    test('選擇版本 lists the original first', () {
      final list = originalsFirst('可愛いあの子が気にゐらない', 'なるみや', kawaiiJa.reversed.toList());
      expect(list.first.artist, 'なるみや');
      expect(list.length, 3);
    });
  });

  test('a song downloaded as a song gets its name as the file name', () {
    expect(DownloadService.fileNameFor('知らないままで', '/tmp/As you don\'t know.m4a'), '知らないままで.m4a');
    expect(DownloadService.fileNameFor('AC/DC: Live?', '/tmp/x.opus'), 'AC_DC_ Live_.opus');
    expect(DownloadService.fileNameFor(null, '/tmp/Gurenge.m4a'), 'Gurenge.m4a');
  });

  test('a failed sync is kept in 同步紀錄', () {
    final src = File('lib/providers/sync_provider.dart').readAsStringSync();
    expect(src, contains("SyncLogEntry(DateTime.now(), '同步失敗：\$e')"));
  });

  test('重新傳送 on a greyed song and in the playlist menu', () {
    expect(File('lib/ui/widgets/track_tile.dart').readAsStringSync(), contains("Text('重新傳送')"));
    expect(File('lib/ui/pages/collection_page.dart').readAsStringSync(), contains("Text('重新傳送缺少的歌曲')"));
  });
}
