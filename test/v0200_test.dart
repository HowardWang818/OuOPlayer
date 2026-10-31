import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/services/volume_normalizer.dart';
import 'package:ouoplayer/ui/widgets/song_font.dart';

void main() {
  group('音量平衡 before a song change', () {
    test('never louder than either song, so the next one cannot start with a blast', () {
      expect(gainBeforeSwitch(6, -3), -3);
      expect(gainBeforeSwitch(-3, 6), -3);
      expect(gainBeforeSwitch(-2, -2), -2);
    });

    test('only in the last moments of a song', () {
      const song = Duration(minutes: 3);
      expect(endingSoon(const Duration(minutes: 2, seconds: 59), song), isTrue);
      expect(gainLead, const Duration(seconds: 1));
      expect(endingSoon(const Duration(minutes: 2), song), isFalse);
      expect(endingSoon(Duration.zero, null), isFalse);
      // A clip shorter than the lead isn't "ending" from its first moment.
      expect(endingSoon(Duration.zero, const Duration(seconds: 1)), isFalse);
    });
  });

  test('the title font defaults to Noto 500', () {
    expect(SongFont.parse(null), SongFont.noto500);
    expect(SongFont.parse('yuGothic'), SongFont.yuGothic);
    expect(SongFont.parse('gone'), SongFont.noto500);
  });
}
