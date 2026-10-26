import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/providers/providers.dart';
import 'package:ouoplayer/services/volume_normalizer.dart';
import 'package:ouoplayer/ui/widgets/track_links.dart';

void main() {
  test('the player opens the first credited artist, like the library', () {
    expect(primaryArtist(const Track(id: 'a', uri: 'a', title: 'x', artist: 'YOASOBI, Ayase')), 'YOASOBI');
    expect(primaryArtist(const Track(id: 'a', uri: 'a', title: 'x', artist: 'DECO*27 feat. 初音ミク')), 'DECO*27');
  });

  test('only files on this device can be shown in a folder', () {
    expect(isLocalFile(const Track(id: '/m/a.mp3', uri: '/m/a.mp3', title: 'a')), isTrue);
    expect(isLocalFile(const Track(id: 'https://x/a.mp3', uri: 'https://x/a.mp3', title: 'a', source: TrackSource.url)), isFalse);
    expect(isLocalFile(const Track(id: 'm', uri: '', title: 'a', source: TrackSource.missing)), isFalse);
    expect(hasPages(const Track(id: 'e', uri: 'https://x/e.mp3', title: 'e', source: TrackSource.podcast)), isFalse);
  });

  test('normalization levels differ and never use the wobbly short window', () {
    String level(NormalizeLevel l) =>
        windowsFilterValues(normalize: true, level: l).firstWhere((v) => v.$1 == 'volume@level').$3;
    expect([for (final l in NormalizeLevel.values) level(l)], ['-8dB', '0dB', '4dB']);
    expect(windowsFilterChain(windowsFilterValues(normalize: true, level: NormalizeLevel.normal)), contains('g=51'));
  });
}
