import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/download_match.dart';
import 'package:ouoplayer/services/download_service.dart';
import 'package:ouoplayer/services/lyrics/lrc.dart';
import 'package:ouoplayer/services/missing_files.dart';
import 'package:ouoplayer/services/track_sort.dart';

void main() {
  group('same title, different artist', () {
    test('Topic channels lose the suffix; credits match loosely', () {
      expect(cleanArtist('9Lana - Topic'), '9Lana');
      expect(cleanArtist('  '), isNull);
      expect(sameArtist('natori', '9Lana'), isFalse);
      expect(sameArtist('YOASOBI', 'Ayase / YOASOBI'), isTrue);
      expect(sameArtist('', 'natori'), isFalse);
    });

    test('playlist entries carry the artist', () {
      const out = '{"title": "Liked", "extractor_key": "YoutubeTab", "entries": ['
          '{"id": "a", "url": "https://music.youtube.com/watch?v=a", "title": "propose", "channel": "9Lana - Topic"},'
          '{"id": "b", "url": "https://music.youtube.com/watch?v=b", "title": "propose", "artists": ["natori"], "channel": "x"},'
          '{"id": "c", "url": "https://music.youtube.com/watch?v=c", "title": "no artist"}]}';
      final l = PlaylistListing.parse(out)!;
      expect(l.entries.map((e) => e.artist), ['9Lana', 'natori', null]);
    });

    test('both 「propose」 files are candidates for the title', () {
      final files = ExistingFiles({
        'propose': ['/m/propose.mp3'],
        'propose9lana': ['/m/propose - 9Lana.mp3'],
      });
      expect(files.candidates('propose', '9Lana'), ['/m/propose.mp3', '/m/propose - 9Lana.mp3']);
      expect(files.candidates('propose'), ['/m/propose.mp3']);
    });
  });

  group('missing files', () {
    const music = '/storage/emulated/0/Music';
    const sd = '/storage/SDCARD/Music';
    Track t(String uri, [String source = TrackSource.download]) => Track(id: uri, uri: uri, title: uri, source: source);

    test('only gone local/downloaded files under readable folders', () {
      final tracks = [
        t('$music/here.mp3'),
        t('$music/gone.mp3'),
        t('$sd/gone.mp3', TrackSource.local),
        t('https://x/a.mp3', TrackSource.url),
        t('/elsewhere/gone.mp3', TrackSource.local),
      ];
      final missing = findMissingTracks(tracks, [music, sd],
          fileExists: (f) => f.endsWith('here.mp3'), dirReadable: (d) => d == music);
      // The SD card can't be read: its songs are left alone.
      expect(missing.map((x) => x.uri), ['$music/gone.mp3', '/elsewhere/gone.mp3']);
    });
  });

  group('sorting', () {
    final songs = [
      const Track(id: '1', uri: '1', title: 'b', artist: 'Z', album: 'x', durationMs: 200, addedAt: 3),
      const Track(id: '2', uri: '2', title: 'A', artist: 'y', album: 'x', addedAt: 1),
      const Track(id: '3', uri: '3', title: 'c', artist: 'x', album: 'x', durationMs: 100, addedAt: 2),
    ];
    List<String> ids(TrackSort s) => [for (final i in s.order(songs)) songs[i].id];

    test('songs', () {
      expect(ids(TrackSort.custom), ['1', '2', '3']);
      expect(ids(const TrackSort(TrackSortKey.title)), ['2', '1', '3']);
      expect(ids(const TrackSort(TrackSortKey.artist)), ['3', '2', '1']);
      expect(ids(const TrackSort(TrackSortKey.added, descending: true)), ['1', '3', '2']);
      // No length → last, in either direction.
      expect(ids(const TrackSort(TrackSortKey.duration)), ['3', '1', '2']);
      expect(ids(const TrackSort(TrackSortKey.duration, descending: true)), ['1', '3', '2']);
      // Same album: original order kept.
      expect(ids(const TrackSort(TrackSortKey.album)), ['1', '2', '3']);
    });

    test('saved choice round-trips', () {
      final s = TrackSort.decode(const TrackSort(TrackSortKey.artist, descending: true).encode());
      expect((s.key, s.descending), (TrackSortKey.artist, true));
      expect(TrackSort.decode(null).key, TrackSortKey.custom);
      expect(TrackSort.decode('junk', fallback: const TrackSort(TrackSortKey.title)).key, TrackSortKey.title);
    });

    test('albums and artists', () {
      final albums = [const Album('b', '', null, 1, 5), const Album('a', '', null, 3, 1), const Album('c', '', null, 2, 9)];
      List<String> names(GroupSort s) =>
          s.apply(albums, name: (a) => a.name, count: (a) => a.count, added: (a) => a.added).map((a) => a.name).toList();
      expect(names(const GroupSort(GroupSortKey.name)), ['a', 'b', 'c']);
      expect(names(const GroupSort(GroupSortKey.count)), ['a', 'c', 'b']);
      expect(names(const GroupSort(GroupSortKey.recent)), ['c', 'b', 'a']);
      expect(names(const GroupSort(GroupSortKey.name, descending: true)), ['c', 'b', 'a']);
    });
  });

  group('lyrics', () {
    test('synced LRC with several stamps per line and an offset', () {
      final l = Lyrics.parse('[ti:Song]\n[offset:500]\n[00:01.00][00:10.50]sa\n[00:05.2]mi\n[00:07.123]\n', source: '.lrc 檔');
      expect(l.synced, isTrue);
      expect(l.lines.map((x) => (x.time!.inMilliseconds, x.text)), [(500, 'sa'), (4700, 'mi'), (6623, ''), (10000, 'sa')]);
      expect(l.indexAt(const Duration(milliseconds: 100)), -1);
      expect(l.indexAt(const Duration(seconds: 5)), 1);
      expect(l.indexAt(const Duration(seconds: 60)), 3);
    });

    test('plain text', () {
      final l = Lyrics.parse('\nfirst\n\nsecond\n\n', source: '歌曲檔案');
      expect(l.synced, isFalse);
      expect(l.lines.map((x) => x.text), ['first', '', 'second']);
      expect(l.indexAt(const Duration(seconds: 1)), -1);
      expect(Lyrics.parse('  \n', source: 'x').isEmpty, isTrue);
    });
  });
}
