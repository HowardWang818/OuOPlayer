import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/file_names.dart';
import 'package:ouoplayer/services/missing_songs.dart';
import 'package:ouoplayer/services/online/itunes.dart';

import 'v0120_test.dart' show openDb;

ITunesSong it(String title, String artist, int ms) => ITunesSong(id: title.hashCode, title: title, artist: artist, album: 'a', viewUrl: '', durationMs: ms);

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('ouo_1205'));

  Track song(String file, String title, String artist, {int ms = 200000}) {
    final f = File('${dir.path}/$file')..writeAsStringSync('x');
    return Track(id: f.path, uri: f.path, title: title, artist: artist, album: 'al', durationMs: ms, source: TrackSource.download, addedAt: 1);
  }

  group('檔名用 iTunes 的正式歌名', () {
    test('iTunes has it for sure: its title', () {
      final t = song('【MV】プロポーズ 9Lana cover.m4a', 'プロポーズ', '9Lana', ms: 234400);
      expect(FileNames.officialTitle(t, [it('プロポーズ', '9Lana', 234000), it('プロポーズ (Instrumental)', '9Lana', 234000)]), 'プロポーズ');
    });

    test('another artist, another take or another length: not used', () {
      final t = song('x.m4a', '青のすみか', 'キタニタツヤ', ms: 197000);
      expect(FileNames.officialTitle(t, [it('青のすみか', 'keiko', 197000)]), isNull);
      expect(FileNames.officialTitle(t, [it('青のすみか (Acoustic ver.)', 'キタニタツヤ', 197000)]), isNull);
      expect(FileNames.officialTitle(t, [it('青のすみか', 'キタニタツヤ', 230000)]), isNull);
    });

    test('renamed file keeps its playlist, like and plays', () async {
      final db = await openDb();
      final t = song('U_M_A_A Inc. - Young Girl A _ 少女A.m4a', '少女A', '椎名もた');
      await db.upsertTracks([t]);
      final list = await db.createPlaylist('L');
      await db.addToPlaylist(list, [t]);
      await db.setFavorite(t, true);
      await db.startListening(t, DateTime(2026, 11, 13));
      final after = await FileNames.rename(db, t, '少女A');
      expect(after.uri, '${dir.path}${Platform.pathSeparator}少女A.m4a');
      expect(File(after.uri).existsSync(), isTrue);
      expect(File(t.uri).existsSync(), isFalse);
      expect([for (final x in await db.playlistTracks(list)) x.id], [after.id]);
      expect(await db.favoriteIds(), {after.id});
      expect((await db.db.query('listening_log')).single['track_id'], after.id);
    });

    test('a name taken by another file: 「name - artist」', () async {
      song('propose.m4a', 'propose', 'natori');
      final t = song('dl.m4a', 'propose', '9Lana');
      expect(FileNames.targetFor(t, 'propose'), '${dir.path}${Platform.pathSeparator}propose - 9Lana.m4a');
    });

    test('already named right: nothing to do', () {
      final t = song('少女A.m4a', '少女A', '椎名もた');
      expect(FileNames.targetFor(t, '少女A'), t.uri);
    });
  });

  group('刪除檔案只刪檔案', () {
    test('playlists (synced or not) and likes keep the song, greyed', () async {
      final db = await openDb();
      final t = song('a.m4a', 'a', 'A');
      await db.upsertTracks([t]);
      final list = await db.createPlaylist('L');
      await db.addToPlaylist(list, [t]);
      await db.setFavorite(t, true);
      await MissingSongs.keepPlaces(db, [t]);
      await db.deleteTracks([t.id]);
      final rows = await db.playlistTracks(list);
      expect([for (final x in rows) '${x.title}/${x.source}'], ['a/${TrackSource.missing}']);
      expect([for (final x in await db.favorites()) x.source], [TrackSource.missing]);
    });

    test('plays follow the song: deleted, then downloaded again', () async {
      final db = await openDb();
      final listed = song('a.m4a', '紅蓮華', 'LiSA'), alone = song('b.m4a', '群青', 'YOASOBI');
      await db.upsertTracks([listed, alone]);
      await db.addToPlaylist(await db.createPlaylist('L'), [listed]);
      for (final t in [listed, alone]) {
        await db.startListening(t, DateTime(2026, 11, 13, 9));
        await db.addHistory(t);
      }
      await MissingSongs.keepPlaces(db, [listed, alone]);
      await db.deleteTracks([listed.id, alone.id]);
      // Both downloaded again, under new file names.
      final a2 = song('a (new).m4a', '紅蓮華', 'LiSA'), b2 = song('b (new).m4a', '群青', 'YOASOBI');
      await db.upsertTracks([a2, b2]);
      await MissingSongs.fill(db, [a2]);
      await MissingSongs.adoptPlays(db, b2);
      for (final t in [a2, b2]) {
        expect((await db.db.query('listening_log', where: 'track_id = ?', whereArgs: [t.id])).length, 1, reason: t.title);
        expect((await db.db.query('history', where: 'track_id = ?', whereArgs: [t.id])).length, 1, reason: t.title);
      }
    });

    test('the delete dialog says the places stay', () {
      final src = File('lib/ui/widgets/track_tile.dart').readAsStringSync();
      expect(src, contains("Text('播放清單裡的位置會保留。')"));
      expect(src, isNot(contains('同步的播放清單在另一台也會移除')));
      expect(src, isNot(contains('takeOutOfLists')));
    });
  });

  test('downloads wait for the final file name before the playlist and like', () {
    final src = File('lib/services/download_service.dart').readAsStringSync();
    expect(src, contains('track = await onImported!(track, t);'));
    expect(File('lib/ui/pages/settings/download_settings.dart').readAsStringSync(), contains("Text('整理檔名')"));
  });
}
