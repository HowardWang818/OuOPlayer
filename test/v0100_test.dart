import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/providers/providers.dart';
import 'package:ouoplayer/services/audio_handler.dart';
import 'package:ouoplayer/services/equalizer.dart';
import 'package:ouoplayer/services/volume_normalizer.dart';

void main() {
  group('equalizer', () {
    test('presets and 自訂', () {
      expect(eqGains(EqPreset.bass, const []), [6, 4, 0, 0, 0]);
      expect(eqGains(EqPreset.custom, const [1, 2, 3, 4, 5]), [1, 2, 3, 4, 5]);
      // No saved custom values yet: flat.
      expect(eqGains(EqPreset.custom, const []), [0, 0, 0, 0, 0]);
      expect(EqPreset.byName('nope'), EqPreset.flat);
    });

    test('device bands get the gain at their centre frequency', () {
      const g = [6.0, 4.0, 0.0, 0.0, 0.0];
      expect(eqGainAt(60, g), 6);
      expect(eqGainAt(20, g), 6);
      expect(eqGainAt(230, g), 4);
      expect(eqGainAt(20000, g), 0);
      final between = eqGainAt(120, g);
      expect(between, lessThan(6));
      expect(between, greaterThan(4));
    });

    test('Windows filter chain: equalizer, then normalizer', () {
      expect(windowsEqFilter(const [0, 0, 0, 0, 0]), '');
      expect(windowsEqFilter(const [6, 0, 0, 0, -2]), 'equalizer=f=60:t=o:w=2:g=6.0,equalizer=f=14000:t=o:w=2:g=-2.0');
      expect(windowsAudioFilter(normalize: false, level: NormalizeLevel.normal), '');
      expect(windowsAudioFilter(normalize: true, level: NormalizeLevel.normal), windowsNormalizeFilter(NormalizeLevel.normal));
      expect(windowsAudioFilter(normalize: true, level: NormalizeLevel.normal, eq: const [6, 0, 0, 0, 0]),
          'lavfi=[equalizer=f=60:t=o:w=2:g=6.0,dynaudnorm=f=500:g=31:p=0.9:m=10]');
      expect(windowsAudioFilter(normalize: false, level: NormalizeLevel.normal, eq: const [0, 0, 0, 0, 0]), '');
    });
  });

  test('fades rise and fall smoothly', () {
    expect(fadeVolume(0, 1, 0), 0);
    expect(fadeVolume(0, 1, 1), 1);
    expect(fadeVolume(0, 1, 0.5), closeTo(0.5, 1e-9));
    expect(fadeVolume(1, 0, 1), 0);
    var last = 0.0;
    for (var i = 1; i <= 20; i++) {
      final v = fadeVolume(0, 1, i / 20);
      expect(v, greaterThanOrEqualTo(last));
      last = v;
    }
  });
}
