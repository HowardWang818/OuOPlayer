// 1.20.11: 找封面 takes the song's own album first; lofi / slowed / nightcore
// edits are other versions.
import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/cover_finder.dart';
import 'package:ouoplayer/services/native_names.dart';
import 'package:ouoplayer/services/online/itunes.dart';
import 'package:ouoplayer/services/song_matcher.dart';

ITunesSong _s(int id, String title, String artist, String album, int ms) =>
    ITunesSong(id: id, title: title, artist: artist, album: album, viewUrl: '', artwork: 'https://x/$id/600x600bb.jpg', durationMs: ms);

/// What iTunes gave for 「Luminous Memory」 on 2026-11-15, per store.
class StoreITunes extends ITunesSearch {
  StoreITunes(this.byStore);
  final Map<String, List<ITunesSong>> byStore;
  final stores = <String>[];

  @override
  Future<List<ITunesSong>> search(String query, {int limit = 200, String? store}) async {
    stores.add(store ?? '');
    return byStore[store] ?? const [];
  }
}

Track _t(String artist, {String album = 'Blue Archive 2nd Anniversary'}) => Track(
    id: 'x', uri: 'x', title: 'Luminous Memory', artist: artist, album: album, durationMs: 139213, source: TrackSource.download, addedAt: 1);

void main() {
  final jp = [
    _s(1, 'Luminous Memory', 'ミツキヨ', 'Blue Archive Original Soundtrack Vol.2 ～Searching for the unknown truth～', 137321),
    _s(5, 'Luminous Memory (From "Blue Archive) Lofi', 'VGM Dogg', 'Luminous Memory (From "Blue Archive) Lofi - Single', 141315),
  ];
  final tw = [
    _s(2, 'Luminous Memory', 'ミツキヨ', 'Blue Archive 2nd Anniversary (Original  Game Soundtrack)', 139200),
    _s(5, 'Luminous Memory (From "Blue Archive) Lofi', 'VGM Dogg', 'Luminous Memory (From "Blue Archive) Lofi - Single', 141315),
  ];

  test('the same album, brackets and 「 - Single」 aside', () {
    expect(CoverFinder.sameAlbum('Blue Archive 2nd Anniversary (Original  Game Soundtrack)', 'Blue Archive 2nd Anniversary'), isTrue);
    expect(CoverFinder.sameAlbum('Luminous - Single', 'Luminous'), isTrue);
    expect(CoverFinder.sameAlbum('Blue Archive Original Soundtrack Vol.2', 'Blue Archive 2nd Anniversary'), isFalse);
    expect(CoverFinder.sameAlbum('', ''), isFalse);
  });

  test('Japanese first, but the song\'s own album wins from another store', () async {
    final it = StoreITunes({'JP': jp, 'TW': tw, 'US': tw});
    final hit = await CoverFinder(it, pause: Duration.zero).find(_t('ミツキヨ'));
    expect(hit!.level, MatchLevel.sure);
    expect(hit.song.id, 2);
    expect(it.stores.first, 'JP');
  });

  test('the own album in the first store: no more lookups', () async {
    final it = StoreITunes({'JP': [...jp, ...tw], 'TW': tw, 'US': tw});
    final hit = await CoverFinder(it, pause: Duration.zero).find(_t('ミツキヨ'));
    expect(hit!.song.id, 2);
    expect(it.stores, ['JP']);
  });

  test('no store has the own album: the first sure one', () async {
    final it = StoreITunes({'JP': jp, 'TW': const [], 'US': const []});
    final hit = await CoverFinder(it, pause: Duration.zero).find(_t('ミツキヨ'));
    expect(hit!.song.id, 1);
    expect(hit.level, MatchLevel.sure);
  });

  test('a lofi edit is never the cover', () async {
    expect(isOtherVersion('Luminous Memory (From "Blue Archive) Lofi', 'Luminous Memory'), isTrue);
    expect(isOtherVersion('Song (Slowed + Reverb)', 'Song'), isTrue);
    expect(isOtherVersion('Song (Nightcore)', 'Song'), isTrue);
    expect(isOtherVersion('Lo-Fi Girl', 'Lo-Fi Girl'), isFalse);
    final it = StoreITunes({'JP': [jp[1]], 'TW': [jp[1]], 'US': [jp[1]]});
    expect(await CoverFinder(it, pause: Duration.zero).find(_t('Blue Archive', album: '未知專輯')), isNull);
  });
}
