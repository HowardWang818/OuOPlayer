import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/audio_handler.dart';
import 'package:ouoplayer/services/cover_finder.dart';
import 'package:ouoplayer/services/native_names.dart';
import 'package:ouoplayer/services/online/itunes.dart';

import 'v0120_test.dart' show openDb;

ITunesSong _s(String title, String artist, int sec) =>
    ITunesSong(id: '$title$artist'.hashCode, title: title, artist: artist, album: 'al', viewUrl: '', durationMs: sec * 1000, artwork: 'https://x/a.jpg');

void main() {
  test('songs queued by hand stay right after the current one when shuffling', () {
    // 1 is playing; 8 and 9 were queued by hand.
    final shuffled = [1, 5, 2, 9, 7, 3, 8];
    expect(withUpNext(shuffled, 1, [8, 9]), [1, 8, 9, 5, 2, 7, 3]);
    expect(withUpNext([4, 1, 2], 1, const <int>[]), [4, 1, 2]);
  });

  test('songs a lookup found nothing for are remembered per kind', () async {
    final db = await openDb();
    await db.setLookupMiss('cover', 'a', true);
    await db.setLookupMiss('cover', 'b', true);
    await db.setLookupMiss('lyrics', 'a', true);
    await db.setLookupMiss('cover', 'b', false);
    expect(await db.lookupMisses('cover'), {'a'});
    expect(await db.lookupMisses('lyrics'), {'a'});
    expect(await db.lookupMisses('native'), isEmpty);
  });

  test('covers of piano, music-box and cover versions are not taken', () {
    expect(isOtherVersion('打上花火 (Piano Ver.) Piano Echoes', 'Uchiage Hanabi'), isTrue);
    expect(isOtherVersion('Lemon KYOTO MUSIC BOX ENSEMBLE', 'Lemon'), isTrue);
    expect(isOtherVersion('Lemon 米津玄師', 'Lemon'), isFalse);
    // The song itself is a piano version: then piano versions are fine.
    expect(isOtherVersion('Lemon (Piano Ver.)', 'Lemon (Piano Ver.)'), isFalse);

    const t = Track(id: 'l', uri: 'l', title: 'Lemon', artist: '米津玄師', album: 'Lemon', durationMs: 256000, source: TrackSource.download);
    final (song, _) = CoverFinder.pick(t, [_s('Lemon', 'KYOTO MUSIC BOX ENSEMBLE', 256), _s('Lemon', '米津玄師', 256)]);
    expect(song?.artist, '米津玄師');
  });
}
