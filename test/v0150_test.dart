import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/artists.dart';
import 'package:ouoplayer/services/cover_finder.dart';
import 'package:ouoplayer/services/online/itunes.dart';
import 'package:ouoplayer/services/song_matcher.dart';

import 'v0120_test.dart' as v0120;

Track song(String id, String title, String artist, {String source = TrackSource.download}) =>
    Track(id: id, uri: id, title: title, artist: artist, source: source);

void main() {
  group('splitting credits', () {
    test('repeats, separators, Topic channels', () {
      expect(splitArtists('YOASOBI, YOASOBI, Ayase'), ['YOASOBI', 'Ayase']);
      expect(splitArtists('DECO*27 feat. 初音ミク'), ['DECO*27', '初音ミク']);
      expect(splitArtists('YOASOBI - Topic'), ['YOASOBI']);
      expect(splitArtists('A & B / C、D'), ['A', 'B', 'C', 'D']);
      expect(splitArtists('未知演出者'), isEmpty);
    });

    test('spellings are merged; members stay apart', () {
      final dir = ArtistDirectory(['韋禮安 WeiBird', 'YOASOBI, Ayase']);
      expect(dir.keyOf('Li Ronghao'), dir.keyOf('李榮浩'));
      expect(dir.keyOf('Ronghao Li'), dir.keyOf('李荣浩'));
      expect(dir.keyOf('Kenshi Yonezu'), dir.keyOf('米津玄師'));
      // Learnt from 「韋禮安 WeiBird」 (also built in).
      expect(dir.keyOf('WeiBird'), dir.keyOf('韋禮安'));
      expect(dir.keyOf('Ayase'), isNot(dir.keyOf('YOASOBI')));
      expect(dir.namesOf('YOASOBI, YOASOBI, Ayase'), ['YOASOBI', 'Ayase']);
    });

    test('a bilingual name in the library teaches a new pair', () {
      final dir = ArtistDirectory(['某某樂團 Some Band', 'Some Band']);
      expect(dir.keyOf('Some Band'), dir.keyOf('某某樂團'));
    });

    test('vocal synths and their spellings', () {
      final dir = ArtistDirectory(const []);
      expect(dir.isVirtual('初音ミク'), isTrue);
      expect(dir.isVirtual('Hatsune Miku'), isTrue);
      expect(dir.keyOf('Kasane Teto'), dir.keyOf('重音テト'));
      expect(dir.keyOf('KAFU'), dir.keyOf('可不'));
      expect(dir.keyOf('Megpoid'), dir.keyOf('GUMI'));
      expect(dir.isVirtual('DECO*27'), isFalse);
      expect(dir.isVirtual('YOASOBI'), isFalse);
    });

    test('the matcher knows the built-in spellings', () {
      expect(SongMatcher.compare(SongKey('Lemon', 'Kenshi Yonezu'), SongKey('Lemon', '米津玄師')).level, MatchLevel.sure);
      expect(SongMatcher.compare(SongKey('ヴァンパイア', 'DECO*27 feat. 初音ミク'), SongKey('ヴァンパイア', 'Hatsune Miku')).level, MatchLevel.sure);
    });
  });

  test('the artists list has one entry per artist with all their songs', () async {
    final db = await v0120.openDb();
    for (final t in [
      song('1', '群青', 'YOASOBI'),
      song('2', '夜に駆ける', 'YOASOBI, YOASOBI, Ayase'),
      song('3', 'ラブカ?', 'Ayase, 柊キライ'),
      song('4', 'ヴァンパイア', 'DECO*27 feat. 初音ミク'),
      song('5', 'テトリス', '柊マグネタイト feat. 重音テト'),
      song('6', '李白', 'Li Ronghao'),
      song('7', '模特', '李榮浩'),
      song('8', 'x', '未知演出者'),
    ]) {
      await db.db.insert('tracks', t.toMap());
    }
    final artists = await db.artists();
    final byName = {for (final a in artists) a.name: a};
    expect(byName['YOASOBI']!.count, 2);
    expect(byName['Ayase']!.count, 2);
    expect(byName['初音ミク']!.virtual, isTrue);
    expect(byName['重音テト']!.virtual, isTrue);
    expect(byName['DECO*27']!.virtual, isFalse);
    expect(byName['李榮浩']!.count, 2);
    expect(byName['未知演出者']!.count, 1);
    expect(artists.where((a) => a.name.contains(',')), isEmpty);
    expect((await db.artistTracks('Ayase')).map((t) => t.id).toSet(), {'2', '3'});
    expect((await db.artistTracks('Hatsune Miku')).single.id, '4');
    expect((await db.artistTracks('Ronghao Li')).map((t) => t.id).toSet(), {'6', '7'});

    // Removing Ayase's solo song leaves Ayase (still on 夜に駆ける).
    expect((await db.removalImpact(['3'])).emptyArtists, ['柊キライ']);
  });

  test('covers: only a confirmed song gives its cover', () {
    const t = Track(id: 'a', uri: 'a', title: 'YOASOBI「アイドル」Official Music Video', artist: 'Ayase / YOASOBI', source: TrackSource.download);
    const right = ITunesSong(id: 1, title: 'アイドル', artist: 'YOASOBI', album: 'アイドル - Single', viewUrl: '', artwork: 'https://x/600x600bb.jpg');
    const wrong = ITunesSong(id: 2, title: 'アイドル', artist: 'Someone Else', album: 'X', viewUrl: '', artwork: 'https://x/other.jpg');
    final (hit, r) = CoverFinder.pick(t, [wrong, right]);
    expect((hit?.id, r.level), (1, MatchLevel.sure));
    expect(CoverFinder.pick(t, [wrong]).$1, isNull);
    expect(CoverFinder.wantsCover(t), isTrue);
    expect(CoverFinder.wantsCover(const Track(id: 'b', uri: 'b', title: 'x', art: '/a.jpg')), isFalse);
  });
}
