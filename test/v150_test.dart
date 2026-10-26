import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/providers/providers.dart';
import 'package:ouoplayer/services/loudness.dart';
import 'package:ouoplayer/services/volume_normalizer.dart';

import 'v0120_test.dart' show openDb;

void main() {
  test('every song is brought to the strength\'s loudness with one gain', () {
    // A loud master (like BUNNY GIRL) comes down; a quiet one goes up.
    expect(songGain(const SongLoudness(-7, -0.1), NormalizeLevel.normal), closeTo(-7, 0.001));
    expect(songGain(const SongLoudness(-18, -8), NormalizeLevel.normal), closeTo(4, 0.001));
    expect(songGain(const SongLoudness(-14, -1), NormalizeLevel.quiet), closeTo(-6, 0.001));
    expect(songGain(const SongLoudness(-14, -1), NormalizeLevel.loud), closeTo(4, 0.001));
  });

  test('a quiet song is only raised as far as its peaks allow', () {
    // Peaks at −2 dBFS: up to 5 dB more (peaks at most 4 dB into the limiter at −1).
    expect(songGain(const SongLoudness(-22, -2), NormalizeLevel.normal), closeTo(5, 0.001));
    expect(songGain(const SongLoudness(-20, 0), NormalizeLevel.loud), closeTo(3, 0.001));
    // Peaks already far over: not raised at all.
    expect(songGain(const SongLoudness(-20, 3.5), NormalizeLevel.loud), 0);
  });

  test("ffmpeg's ebur128 summary is read", () {
    const log = '''
[Parsed_ebur128_0 @ 0x1] t: 1.2  M: -20.1 S:-120.7     I: -21.0 LUFS       LRA:   0.0 LU
[Parsed_ebur128_0 @ 0x1] Summary:

  Integrated loudness:
    I:          -9.4 LUFS
    Threshold: -19.6 LUFS

  Sample peak:
    Peak:        0.3 dBFS
''';
    final l = parseEbur128(log)!;
    expect(l.lufs, -9.4);
    expect(l.peak, 0.3);
    expect(parseEbur128('    I:         -70.0 LUFS\n    Peak:       -inf dBFS'), isNull);
  });

  test('Windows: a measured song turns the adaptive normalizer off', () {
    final v = windowsFilterValues(normalize: true, level: NormalizeLevel.normal, songGainDb: -6.5);
    expect(v, contains(('dynaudnorm@norm', 'p', '1')));
    expect(v, contains(('dynaudnorm@norm', 'm', '1')));
    expect(v, contains(('volume@level', 'volume', '-6.5dB')));
    final unknown = windowsFilterValues(normalize: true, level: NormalizeLevel.normal);
    expect(unknown, contains(('dynaudnorm@norm', 'p', '0.8')));
  });

  test('measured loudness is kept in the library', () async {
    final db = await openDb();
    expect(await db.loudness('a'), isNull);
    await db.setLoudness('a', -9.4, -0.2);
    final l = (await db.loudness('a'))!;
    expect((l.lufs, l.peak), (-9.4, -0.2));
    expect(await db.loudnessIds(), {'a'});
  });
}
