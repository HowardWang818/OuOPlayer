// 1.20.12: 改成原文歌名 after a download keeps the new cover; 找封面 takes
// the song's own album even with the artist written another way; an artist
// under its romaji and original names becomes one.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/artist_merge.dart';
import 'package:ouoplayer/services/artists.dart';
import 'package:ouoplayer/services/cover_finder.dart';
import 'package:ouoplayer/services/native_names.dart';
import 'package:ouoplayer/services/song_matcher.dart';

import 'v0120_test.dart' show openDb;
import 'v12011_test.dart' show StoreITunes;
import 'package:ouoplayer/services/online/itunes.dart';

ITunesSong _s(int id, String title, String artist, String album, int ms) =>
    ITunesSong(id: id, title: title, artist: artist, album: album, viewUrl: '', artwork: 'https://x/$id/600x600bb.jpg', durationMs: ms);

Track _song(String title, String artist, String album, int ms, {String? art}) =>
    Track(id: title, uri: title, title: title, artist: artist, album: album, durationMs: ms, art: art, source: TrackSource.download, addedAt: 1);

void main() {
  group('找封面: the own album, artist written another way', () {
    test('Luminous Memory by ミツキヨ → 2nd Anniversary', () async {
      final it = StoreITunes({
        'JP': [_s(1, 'Luminous Memory', 'ミツキヨ', 'Blue Archive Original Soundtrack Vol.2 ～Searching for the unknown truth～', 137321)],
        'TW': [_s(2, 'Luminous Memory', 'Mitsukiyo', 'Blue Archive 2nd Anniversary (Original  Game Soundtrack)', 139200)],
        'US': [_s(2, 'Luminous Memory', 'Mitsukiyo', 'Blue Archive 2nd Anniversary (Original  Game Soundtrack)', 139200)],
      });
      final hit = await CoverFinder(it, pause: Duration.zero).find(_song('Luminous Memory', 'ミツキヨ', 'Blue Archive 2nd Anniversary', 139213));
      expect(hit!.song.id, 2);
      expect(hit.level, MatchLevel.sure);
    });

    test('Unwelcome School by ミツキヨ → 3rd Anniversary', () async {
      final it = StoreITunes({
        'JP': [_s(1, 'Unwelcome School', 'ミツキヨ', 'Blue Archive Original Soundtrack Vol.4 ～Aiming for the ideal freedom～', 120293)],
        'TW': [_s(3, 'Unwelcome School', 'Mitsukiyo', 'Blue Archive 3rd Anniversary (Original Soundtrack)', 120707)],
        'US': [_s(3, 'Unwelcome School', 'Mitsukiyo', 'Blue Archive 3rd Anniversary (Original Soundtrack)', 120707)],
      });
      final hit = await CoverFinder(it, pause: Duration.zero).find(_song('Unwelcome School', 'ミツキヨ', 'Blue Archive 3rd Anniversary', 120713));
      expect(hit!.song.id, 3);
    });

    test('not the same length or another version: not taken that way', () {
      final t = _song('Luminous Memory', 'ミツキヨ', 'x', 139213);
      expect(CoverFinder.sameRecording(t, _s(1, 'Luminous Memory', 'Mitsukiyo', 'x', 139200)), isTrue);
      expect(CoverFinder.sameRecording(t, _s(1, 'Luminous Memory', 'Mitsukiyo', 'x', 150000)), isFalse);
      expect(CoverFinder.sameRecording(t, _s(1, 'Luminous Memory (Lofi)', 'Mitsukiyo', 'x', 139200)), isFalse);
    });
  });

  test('改成原文歌名 keeps the cover found after the song was looked up', () async {
    final db = await openDb();
    final before = _song('Unwelcome School', 'Mitsukiyo', 'Blue Archive 3rd Anniversary', 120713, art: 'thumb.jpg');
    await db.upsertTracks([before]);
    // DownloadFinish put the official cover in meanwhile.
    await db.db.update('tracks', {'art': 'itunes.jpg'}, where: 'id = ?', whereArgs: [before.id]);
    final done = await NativeNames.apply(db, NativeName(before, title: before.title, artist: 'ミツキヨ', album: before.album));
    expect(done!.art, 'itunes.jpg');
    expect((await db.track(before.id))!.art, 'itunes.jpg');
    expect((await db.track(before.id))!.artist, 'ミツキヨ');
  });

  group('one artist, two names', () {
    Future<Map<String, String>> renames(dynamic db) async =>
        (jsonDecode((await db.allSettings())['artist_renames'] ?? '{}') as Map).cast<String, String>();

    tearDown(() => ArtistRenames.set(const {}));

    test('pairs of a renamed credit', () {
      expect(ArtistMerge.pairs('Rokudenashi', 'ロクデナシ'), [('Rokudenashi', 'ロクデナシ')]);
      expect(ArtistMerge.pairs('Rokudenashi, Ayase', 'ロクデナシ, Ayase'), [('Rokudenashi', 'ロクデナシ')]);
      expect(ArtistMerge.pairs('YOASOBI', 'YOASOBI'), isEmpty);
      expect(ArtistMerge.pairs('A, B', 'エー'), isEmpty);
    });

    test('a song renamed to the original name: the romaji name shows as it everywhere', () async {
      final db = await openDb();
      await ArtistMerge.learn(db, 'natori', 'なとり');
      expect(await renames(db), {'natori': 'なとり'});
      expect(ArtistDirectory(const []).canonical('natori'), 'なとり');
      expect(ArtistDirectory(const []).namesOf('natori, Ayase'), ['なとり', 'Ayase']);
    });

    test('two originals for one romaji name: neither', () async {
      final db = await openDb();
      await ArtistMerge.learn(db, 'Kai', 'カイ');
      await ArtistMerge.learn(db, 'Kai', '甲斐');
      expect(await renames(db), isEmpty);
      await ArtistMerge.learn(db, 'Kai', 'カイ');
      expect(await renames(db), isEmpty);
    });

    test('the user\'s own name stays; 還原 keeps them apart for good', () async {
      final db = await openDb();
      await db.setSetting('artist_renames', jsonEncode({'Eve': 'イブ'}));
      await ArtistMerge.learn(db, 'Eve', 'イヴ');
      expect(await renames(db), {'Eve': 'イブ'});
      await ArtistMerge.learn(db, 'Rokudenashi', 'ロクデナシ');
      await db.setSetting('artist_renames', jsonEncode({'Eve': 'イブ'}));
      await ArtistMerge.keepApart(db, ['Rokudenashi']);
      await ArtistMerge.learn(db, 'Rokudenashi', 'ロクデナシ');
      expect(await renames(db), {'Eve': 'イブ'});
    });

    test('once: the renames made before, by 改成原文歌名 and through sync', () async {
      final db = await openDb();
      await db.upsertTracks([_song('Spica', 'Rokudenashi', 'x', 1000), _song('Unwelcome School', 'ミツキヨ', 'x', 1000)]);
      await db.setSetting('sync_names', jsonEncode({
        'propose|natori': {'from': {'title': 'Propose', 'artist': 'natori', 'ms': 1}, 'title': 'プロポーズ', 'artist': 'なとり', 'album': 'x'},
      }));
      await db.db.insert('track_edits', {'track_id': 'Unwelcome School', 'root': 'unwelcomeschool|mitsukiyo', 'root_ms': 1000, 'title': 'Unwelcome School', 'artist': 'ミツキヨ', 'album': 'x', 'at': 1, 'device': 'pc'});
      await db.db.insert('track_edits', {'track_id': 'Spica', 'root': 'spica|rokudenashi', 'root_ms': 1000, 'title': 'スピカ', 'artist': 'ロクデナシ', 'album': 'x', 'at': 1, 'device': 'pc'});
      await ArtistMerge.learnOld(db);
      expect(await renames(db), {'natori': 'なとり', 'mitsukiyo': 'ミツキヨ', 'Rokudenashi': 'ロクデナシ'});
      expect(ArtistDirectory(const []).canonical('Mitsukiyo'), 'ミツキヨ');
      await db.setSetting('artist_renames', '{}');
      await ArtistMerge.learnOld(db);
      expect(await renames(db), isEmpty, reason: 'only once');
    });
  });
}
