import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/missing_songs.dart';
import 'package:ouoplayer/ui/pages/missing_songs_page.dart';

import 'v0120_test.dart' as v0120;

void main() {
  test('a missing song stays in its place and is filled in when it turns up', () async {
    final db = await v0120.openDb();
    const a = Track(id: '/m/a.mp3', uri: '/m/a.mp3', title: '群青', artist: 'YOASOBI', source: TrackSource.download);
    await db.db.insert('tracks', a.toMap());
    final gone = await MissingSongs.create(db, '如果可以', 'WeiBird');
    final pl = await db.createPlaylist('通勤');
    await db.addToPlaylist(pl, [a, gone], allowDuplicates: true);
    await db.setFavorite(gone, true);

    // Placeholders aren't library songs and don't count as songs.
    expect((await db.tracks()).map((t) => t.id), ['/m/a.mp3']);
    final info = (await db.playlists()).single;
    expect((info.count, info.missing), (1, 1));

    // Another song: nothing to fill.
    const other = Track(id: '/m/b.mp3', uri: '/m/b.mp3', title: '如果', artist: 'Someone', source: TrackSource.download);
    expect(await MissingSongs.fill(db, [other]), isEmpty);

    // The download arrives with its YouTube title.
    const real = Track(
        id: '/m/c.opus', uri: '/m/c.opus', title: '韋禮安 WeiBird《如果可以 Red Scarf》MV - 電影「月老」主題曲', artist: '韋禮安 WeiBird', source: TrackSource.download);
    await db.db.insert('tracks', real.toMap());
    final filled = await MissingSongs.fill(db, [real]);
    expect(filled.single.playlists, containsAll(['通勤', '已按讚的歌曲']));
    expect((await db.playlistTracks(pl)).map((t) => t.id), ['/m/a.mp3', '/m/c.opus']);
    expect(await db.favoriteIds(), {'/m/c.opus'});
    expect(await MissingSongs.all(db), isEmpty);
  });

  test('links text, quota and the Soundiiz tip', () {
    const t = Track(id: 'missing:1', uri: '', title: '如果可以', artist: 'WeiBird', source: TrackSource.missing);
    expect(linksText([(t, const FoundLink('https://music.youtube.com/watch?v=x', '', '', true))]),
        '如果可以 - WeiBird：https://music.youtube.com/watch?v=x');
    expect(quotaPercent(50), 50);
    expect(quotaPercent(500), 100);
    expect(linkQuery(const Track(id: 'm', uri: '', title: '【MV】怪物 / YOASOBI', artist: 'YOASOBI - Topic')), '怪物 YOASOBI');
    expect(suggestSoundiiz(5, 20), isFalse);
    expect(suggestSoundiiz(12, 20), isTrue);
    expect(suggestSoundiiz(30, 1000), isTrue);
  });
}
