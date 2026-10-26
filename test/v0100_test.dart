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

    test('Windows chain: built once, values change live', () {
      final off = windowsFilterValues(normalize: false, level: NormalizeLevel.normal);
      // Everything neutral when off: normalizer at peak 1 / gain 1, flat EQ.
      expect(off, contains(('dynaudnorm@norm', 'p', '1')));
      expect(off, contains(('dynaudnorm@norm', 'm', '1')));
      expect(off, contains(('volume@level', 'volume', '0dB')));
      expect(off, contains(('volume@headroom', 'volume', '-0.0dB')));
      expect(off, contains(('equalizer@b0', 'g', '0.0')));
      final on = windowsFilterValues(normalize: true, level: NormalizeLevel.quiet, eq: const [6, 0, 0, 0, -2]);
      expect(on, contains(('dynaudnorm@norm', 'm', '4')));
      expect(on, contains(('volume@level', 'volume', '-8dB')));
      // Half the biggest boost as headroom.
      expect(on, contains(('volume@headroom', 'volume', '-3.0dB')));
      expect(on, contains(('equalizer@b4', 'g', '-2.0')));
      expect(
          windowsFilterChain(on),
          '@ouo:lavfi=[dynaudnorm@norm=f=500:g=51:p=0.8:m=4,volume@level=volume=-8dB,volume@headroom=volume=-3.0dB,'
          'equalizer@b0=f=60:t=o:w=2:g=6.0,equalizer@b1=f=230:t=o:w=2:g=0.0,equalizer@b2=f=910:t=o:w=2:g=0.0,'
          'equalizer@b3=f=3600:t=o:w=2:g=0.0,equalizer@b4=f=14000:t=o:w=2:g=-2.0,'
          'alimiter@limit=limit=0.95:attack=10:release=300:level=0]');
      // Same filters whatever the settings: only values differ.
      String shape(String chain) => chain.replaceAll(RegExp(r'=-?[0-9.]+(dB)?'), '=');
      expect(shape(windowsFilterChain(off)), shape(windowsFilterChain(on)));
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
