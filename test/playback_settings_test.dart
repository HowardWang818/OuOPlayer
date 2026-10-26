import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/providers/providers.dart';
import 'package:ouoplayer/services/sleep_timer.dart';
import 'package:ouoplayer/services/volume_normalizer.dart';

void main() {
  test('sleep timer fades only during the last 10 seconds', () {
    expect(fadeFactor(const Duration(minutes: 5)), 1.0);
    expect(fadeFactor(const Duration(seconds: 10)), 1.0);
    expect(fadeFactor(const Duration(seconds: 5)), 0.5);
    expect(fadeFactor(Duration.zero), 0.0);
    expect(fadeFactor(const Duration(seconds: -3)), 0.0);
  });

  test('each normalization strength has its own mpv values', () {
    final values = {for (final l in NormalizeLevel.values) windowsFilterValues(normalize: true, level: l).toString()};
    expect(values, hasLength(3));
  });

  test('playback option lists include the defaults', () {
    expect(podcastSpeeds, contains(1.0));
    expect(seekSecondOptions, contains(15));
  });
}
