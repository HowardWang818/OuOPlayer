import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/services/online/itunes.dart';
import 'package:ouoplayer/services/online/preview_match.dart';

ITunesSong it(int id, String title, String artist, {String? preview}) =>
    ITunesSong(id: id, title: title, artist: artist, album: '', viewUrl: 'https://x/$id', previewUrl: preview);

void main() {
  group('試聽用 iTunes 30 秒', () {
    test('the same song with a preview is played', () {
      final found = previewMatch('群青', 'YOASOBI', [
        it(1, '群青', 'Someone', preview: 'https://audio/1.m4a'),
        it(2, '群青', 'YOASOBI', preview: 'https://audio/2.m4a'),
      ]);
      expect(found?.id, 2);
    });

    test('no preview, another artist or nothing found: no preview', () {
      expect(previewMatch('群青', 'YOASOBI', [it(1, '群青', 'YOASOBI')]), isNull);
      expect(previewMatch('propose', 'natori', [it(1, 'propose', '9Lana', preview: 'https://a')]), isNull);
      expect(previewMatch('Hip Hop BGM', 'Lo-Fi Japan', const []), isNull);
    });

    test('YouTube is no longer streamed for previews', () {
      expect(File('lib/services/download_service.dart').readAsStringSync(), isNot(contains('streamUrl')));
      final search = File('lib/ui/pages/search_page.dart').readAsStringSync();
      expect(search, contains('previewMatch('));
      expect(search, isNot(contains('streamUrl')));
    });
  });

  group('試聽不換版本', () {
    ITunesSong v(int id, String title, {String album = '', int? ms}) =>
        ITunesSong(id: id, title: title, artist: 'YOASOBI', album: album, viewUrl: 'https://x/$id', previewUrl: 'https://a/$id', durationMs: ms);

    test('the studio song skips THE FIRST TAKE and live takes', () {
      final found = previewMatch('夜に駆ける', 'YOASOBI', [
        v(1, '夜に駆ける - From THE FIRST TAKE', ms: 262000),
        v(2, '夜に駆ける (Live)', ms: 270000),
        v(3, '夜に駆ける', ms: 261000),
      ], durationMs: 261000);
      expect(found?.id, 3);
    });

    test('only a live take found: no preview rather than the wrong one', () {
      expect(previewMatch('夜に駆ける', 'YOASOBI', [v(1, '夜に駆ける (Live)')]), isNull);
    });

    test('a live song looks for its live take', () {
      final found = previewMatch('夜に駆ける (Live)', 'YOASOBI', [v(1, '夜に駆ける'), v(2, '夜に駆ける (Live)')]);
      expect(found?.id, 2);
    });

    test('far too long is not the same recording', () {
      expect(previewMatch('夜に駆ける', 'YOASOBI', [v(1, '夜に駆ける', ms: 400000)], durationMs: 261000), isNull);
    });
  });

  test('no 取得 YouTube Music 連結 left on screen', () {
    for (final f in Directory('lib/ui').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      expect(f.readAsStringSync(), isNot(contains('取得 YouTube Music 連結')), reason: f.path);
    }
    expect(File('lib/ui/widgets/track_tile.dart').readAsStringSync(), contains('downloadMissingSong(context, track)'));
    expect(File('lib/ui/pages/collection_page.dart').readAsStringSync(), contains('downloadMissingSongs(context, missing)'));
  });
}
