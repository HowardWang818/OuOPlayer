import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/download_finish.dart';
import 'package:ouoplayer/services/download_service.dart';
import 'package:ouoplayer/services/online/online_search.dart';

import 'v1196_test.dart' show Dev;
import 'sync2_test.dart' show FakeDrive;

void main() {
  group('線上搜尋選平台', () {
    test('three platforms, YT Music by its short name, none preferred', () {
      expect(OnlineSource.values.map((s) => s.label), ['YT Music', 'YouTube', 'SoundCloud']);
      expect(OnlineSource.byName(null), isNull);
      expect(OnlineSource.byName('soundcloud'), OnlineSource.soundcloud);
      expect(OnlineSource.ytMusic.ytdlpPrefix, isNull);
      expect(OnlineSource.youtube.ytdlpPrefix, 'ytsearch20');
      expect(OnlineSource.soundcloud.ytdlpPrefix, 'scsearch20');
    });

    test('yt-dlp search answers become songs with a page to download', () {
      const out = '[youtube:search] x\n{"entries": ['
          '{"id": "a1", "title": "Lofi BGM", "uploader": "Lofi Girl", "duration": 125.4, "url": "https://www.youtube.com/watch?v=a1", "thumbnails": [{"url": "s.jpg"}, {"url": "l.jpg"}]},'
          '{"id": "b2", "title": "", "url": "https://x"},'
          '{"id": "c3", "title": "Sleepy", "uploader": "nemesis", "url": "https://api.soundcloud.com/tracks/3"}]}';
      final songs = parseYtdlpSearch(out);
      expect(songs, hasLength(2));
      expect(songs.first.url, 'https://www.youtube.com/watch?v=a1');
      expect(songs.first.artist, 'Lofi Girl');
      expect(songs.first.durationMs, 125400);
      expect(songs.first.artwork, 'l.jpg');
      expect(songs.last.durationMs, isNull);
      expect(parseYtdlpSearch('nothing'), isEmpty);
    });

    test('the platform button is only on 網路, the first visit asks for one', () {
      final src = File('lib/ui/pages/search_page.dart').readAsStringSync();
      expect(src, contains('if (online && !s.podcast)'));
      expect(src, contains('firstOnlineVisit(context, ref)'));
    });
  });

  group('下載後的處理', () {
    DownloadTask task({String? title, String? artist, String? album, String? art}) => DownloadTask(id: '1', url: 'u', kind: DownloadKind.ytdlp, format: 'm4a')
      ..metaTitle = title
      ..metaArtist = artist
      ..metaAlbum = album
      ..art = art;
    const t = Track(id: '/m/a.m4a', uri: '/m/a.m4a', title: 'Yoru ni Kakeru (Official Video)', artist: 'Ayase / YOASOBI', album: '未知專輯', source: TrackSource.download);

    test('the names it was found by replace the video title', () {
      final n = DownloadFinish.names(t, task(title: '夜に駆ける', artist: 'YOASOBI', album: 'THE BOOK'));
      expect((n.title, n.artist, n.album), ('夜に駆ける', 'YOASOBI', 'THE BOOK'));
      final kept = DownloadFinish.names(t, task());
      expect(kept.title, t.title);
    });

    test('YT Music and SoundCloud covers are square already; YouTube thumbnails are not', () {
      expect(DownloadFinish.squareArt('https://lh3.googleusercontent.com/x=w544-h544'), isTrue);
      expect(DownloadFinish.squareArt('https://i1.sndcdn.com/artworks-x-t500x500.jpg'), isTrue);
      expect(DownloadFinish.squareArt('https://i.ytimg.com/vi/x/hqdefault.jpg'), isFalse);
      expect(DownloadFinish.squareArt(null), isFalse);
    });

    test('downloads from search and missing songs carry their names', () {
      expect(File('lib/ui/pages/search_page.dart').readAsStringSync(), contains('artist: song.artist, album: song.album'));
      expect(File('lib/ui/widgets/missing_download.dart').readAsStringSync(), contains('artist: t.artist'));
      expect(File('lib/providers/providers.dart').readAsStringSync(), contains('DownloadFinish.apply('));
    });
  });

  group('其他', () {
    test('播放記錄 is gone', () {
      expect(File('lib/services/scrobble.dart').existsSync(), isFalse);
      expect(File('lib/config/lastfm_config.dart').existsSync(), isFalse);
      expect(File('scripts/release.ps1').readAsStringSync(), isNot(contains('lastfm')));
    });

    test('one 匯入播放清單 for M3U, CSV and JSON', () {
      final lib = File('lib/ui/pages/library_page.dart').readAsStringSync();
      expect(lib, contains("title: Text('匯入播放清單')"));
      expect(lib, isNot(contains('匯入 Spotify 歌單')));
    });

    test('one song menu: the player and selections use the same list', () {
      expect(File('lib/ui/widgets/track_tile.dart').readAsStringSync(), contains('showSongMenu('));
      expect(File('lib/ui/widgets/track_selection.dart').readAsStringSync(), contains('songActions('));
      final actions = File('lib/ui/widgets/song_actions.dart').readAsStringSync();
      expect(actions, isNot(contains('前往專輯')));
    });

    test('所有檔案存取權 is asked for', () {
      expect(File('android/app/src/main/AndroidManifest.xml').readAsStringSync(), contains('MANAGE_EXTERNAL_STORAGE'));
    });
  });

  group('在 App 裡刪除檔案', () {
    late FakeDrive drive;
    late Dev phone, pc;
    setUp(() async {
      drive = FakeDrive();
      phone = await Dev.make('phone', drive);
      pc = await Dev.make('pc', drive);
      for (final d in [phone, pc]) {
        for (final s in ['群青', '夜に駆ける', 'アイドル']) {
          await d.song(s);
        }
      }
      final id = await phone.db.createPlaylist('通勤');
      await phone.db.addToPlaylist(id, [for (final t in await phone.db.tracks()) t]);
      await phone.engine.enable(id);
      for (var i = 0; i < 2; i++) {
        await phone.sync();
        await pc.sync();
      }
    });

    test('leaves the playlists here and there, the other device keeps its file', () async {
      final gone = (await phone.db.tracks()).firstWhere((t) => t.title == '群青');
      await phone.db.takeOutOfLists([gone.id]);
      await phone.db.deleteTracks([gone.id]);
      for (var i = 0; i < 2; i++) {
        await phone.sync();
        await pc.sync();
      }
      expect(await phone.titles('通勤'), isNot(contains('群青')));
      expect(await pc.titles('通勤'), isNot(contains('群青')));
      expect((await pc.db.tracks()).map((t) => t.title), contains('群青'), reason: 'the song stays in the other library');
    });

    test('hiding a song still only greys it here', () async {
      final hidden = (await phone.db.tracks()).firstWhere((t) => t.title == '群青');
      await phone.db.deleteTracks([hidden.id]);
      for (var i = 0; i < 2; i++) {
        await phone.sync();
        await pc.sync();
      }
      expect(await pc.titles('通勤'), contains('群青'));
    });
  });
}
