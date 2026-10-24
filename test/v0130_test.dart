import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/spotify_import.dart';

void main() {
  group('reading Spotify exports', () {
    test("Spotify's own Playlist1.json", () {
      const json = '{"playlists": [{"name": "通勤", "lastModifiedDate": "2026-10-01", "items": ['
          '{"track": {"trackName": "群青", "artistName": "YOASOBI", "albumName": "THE BOOK", "trackUri": "spotify:track:1"}, "episode": null},'
          '{"track": null, "episode": {"episodeName": "ep"}},'
          '{"track": {"trackName": "propose", "artistName": "9Lana", "albumName": "propose"}}]}]}';
      final pls = parseSpotifyExport(json, fileName: 'Playlist1.json');
      expect(pls.single.name, '通勤');
      expect(pls.single.songs.map((s) => (s.title, s.artists.join('|'), s.album)), [
        ('群青', 'YOASOBI', 'THE BOOK'),
        ('propose', '9Lana', 'propose'),
      ]);
    });

    test('YourLibrary.json becomes the liked list', () {
      const json = '{"tracks": [{"artist": "natori", "album": "propose", "track": "Propose", "uri": "spotify:track:2"}], "albums": []}';
      final pl = parseSpotifyExport(json, fileName: 'YourLibrary.json').single;
      expect((pl.name, pl.liked, pl.songs.single.title), ('Spotify 按讚', true, 'Propose'));
    });

    test('Exportify CSV with quotes, commas and several artists', () {
      const csv = '﻿Track URI,Track Name,Album Name,Artist Name(s),Release Date,Duration (ms)\r\n'
          'spotify:track:1,群青,THE BOOK,YOASOBI,2020-09-01,248000\r\n'
          'spotify:track:2,"Hello, ""World""",Album,"A, B",2020,180000\r\n'
          '\r\n'
          'spotify:track:3,"Line\nbreak",X,C;D,2021,\r\n';
      final pl = parseSpotifyExport(csv, fileName: 'my_road_trip.csv').single;
      expect(pl.name, 'my road trip');
      expect(pl.songs.map((s) => (s.title, s.artists.join('|'), s.durationMs)), [
        ('群青', 'YOASOBI', 248000),
        ('Hello, "World"', 'A|B', 180000),
        ('Line\nbreak', 'C|D', null),
      ]);
    });

    test('other files give nothing', () {
      expect(parseSpotifyExport('{"foo": 1}', fileName: 'x.json'), isEmpty);
      expect(parseSpotifyExport('not json', fileName: 'x.json'), isEmpty);
      expect(parseSpotifyExport('a,b\n1,2', fileName: 'x.csv'), isEmpty);
    });
  });

  group('finding the songs on the phone', () {
    Track t(String id, String title, String artist, {int? ms}) => Track(id: id, uri: id, title: title, artist: artist, durationMs: ms);
    final lib = SpotifyMatcher([
      t('a', '群青', 'YOASOBI'),
      t('b', 'propose', 'natori'),
      t('c', 'Idol', 'YOASOBI', ms: 213000),
      t('d', 'Idol', 'YOASOBI', ms: 300000),
      t('e', 'Shape of You (Official Audio)', 'Ed Sheeran'),
    ]);

    test('title and artist must match', () {
      expect(lib.find(const SpotifySong('群青', ['YOASOBI']))?.id, 'a');
      expect(lib.find(const SpotifySong('Propose', ['natori']))?.id, 'b');
      // Same title, another artist: not the same song.
      expect(lib.find(const SpotifySong('propose', ['9Lana'])), isNull);
    });

    test('notes in titles and several artists', () {
      expect(lib.find(const SpotifySong('群青 - Remastered 2021', ['YOASOBI']))?.id, 'a');
      expect(lib.find(const SpotifySong('Shape of You', ['Ed Sheeran']))?.id, 'e');
      expect(lib.find(const SpotifySong('群青', ['someone', 'YOASOBI']))?.id, 'a');
    });

    test('closest length wins', () {
      expect(lib.find(const SpotifySong('Idol', ['YOASOBI'], durationMs: 213500))?.id, 'c');
      expect(lib.find(const SpotifySong('Idol', ['YOASOBI'], durationMs: 299000))?.id, 'd');
    });

    test('bare titles', () {
      expect(bareTitle('Idol (Official Audio)'), 'Idol');
      expect(bareTitle('Song - Live at Budokan'), 'Song');
      expect(bareTitle('Song - Remastered 2011'), 'Song');
      expect(bareTitle('Love - Story'), 'Love - Story');
    });
  });
}
