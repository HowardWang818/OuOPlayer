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
}
