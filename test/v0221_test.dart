import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/providers/providers.dart' show NormalizeLevel;
import 'package:ouoplayer/services/volume_normalizer.dart';

void main() {
  test('lowering a song goes after the chain, raising stays ahead of the limiter', () {
    expect(windowsGain(-6.5), (chain: 0.0, output: -6.5));
    expect(windowsGain(4), (chain: 4.0, output: 0.0));
    expect(windowsGain(0), (chain: 0.0, output: 0.0));
  });

  test('the chain text carries no song gain, so it never needs changing between songs', () {
    final text = windowsFilterChain(windowsFilterValues(normalize: true, level: NormalizeLevel.loud, songGainDb: 0));
    expect(text, contains('volume@level=volume=0.0dB'));
    expect(text.indexOf('volume@level'), lessThan(text.indexOf('alimiter@limit')));
  });
}
