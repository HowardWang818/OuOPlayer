import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/native_names.dart';
import 'package:ouoplayer/services/online/itunes.dart';

Track _t(String title, String artist, {int ms = 287000}) =>
    Track(id: title, uri: '/m/$title.m4a', title: title, artist: artist, durationMs: ms, source: TrackSource.download);

ITunesSong _s(String title, String artist, int sec) =>
    ITunesSong(id: '$title$artist'.hashCode, title: title, artist: artist, album: '', viewUrl: '', durationMs: sec * 1000);

void main() {
  test('an original already in brackets is used as it is', () {
    expect(bracketNative('Through the Night (밤편지)'), '밤편지');
    expect(bracketNative('Racing into the Night（夜に駆ける）'), '夜に駆ける');
    expect(bracketNative('Spring Day'), isNull);
    expect(bracketNative('晴天 (Live)'), isNull);
    expect(NativeNames.wants(_t('Through the Night (밤편지)', 'IU')), isTrue);
    expect(NativeNames.wants(_t('晴天', '周杰倫')), isFalse);
  });

  test('Chinese songs get their Chinese names from the Taiwanese store', () {
    final n = NativeNames.pick(_t('Practice Love', 'JJ Lin'), [_s('修煉愛情', '林俊傑', 287)], nativeTitleOnly: true)!;
    expect((n.title, n.artist), ('修煉愛情', '林俊傑'));
    // Notes in brackets are left out.
    final g = NativeNames.pick(_t('Light Years Away', 'G.E.M.', ms: 236000), [_s('光年之外 (電影《Passengers》中國區主題曲)', '鄧紫棋', 236)],
        nativeTitleOnly: true)!;
    expect(g.title, '光年之外');
  });

  test('a foreign artist is not given a Chinese name', () {
    // The Taiwanese store calls BTS 「防彈少年團」; the title stays English, so nothing changes.
    expect(NativeNames.pick(_t('Spring Day', 'BTS', ms: 274000), [_s('Spring Day', '防彈少年團', 274)], nativeTitleOnly: true), isNull);
  });
}
