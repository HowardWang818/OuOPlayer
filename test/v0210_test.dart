import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/cover_finder.dart';
import 'package:ouoplayer/services/library_scanner.dart';
import 'package:ouoplayer/services/lyrics/lyrics_service.dart';
import 'package:ouoplayer/services/online/itunes.dart';
import 'package:ouoplayer/ui/pages/queue_page.dart';
import 'package:ouoplayer/ui/shell/app_shortcuts.dart';

import 'v0120_test.dart' as v0120;
import 'v1111_test.dart' show FakeITunes;

/// LRCLIB with its exact lookup busy and its search working.
class _BusyGet implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    // Several artists in one name stay refused, as on the real LRCLIB.
    final several = '${options.queryParameters['artist_name']}'.contains(',');
    if (options.path.endsWith('/get') || several) return ResponseBody.fromString('busy', 503);
    return ResponseBody.fromString(
      jsonEncode([
        {'trackName': 'The Story of Us', 'artistName': 'milet', 'albumName': 'x', 'duration': 267, 'syncedLyrics': '[00:01.00]line', 'plainLyrics': 'line'}
      ]),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType]
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('a busy exact lookup still finds lyrics through the search', () async {
    final service = LyricsService(LibraryScanner(await v0120.openDb()), dio: Dio()..httpClientAdapter = _BusyGet());
    final r = await service.lookup(const Track(id: 'a', uri: '/m/a.m4a', title: 'The Story of Us', artist: 'milet', durationMs: 267000));
    expect(r?.title, 'The Story of Us');
  });

  test('a refused search under several artists goes on to the first artist', () async {
    final service = LyricsService(LibraryScanner(await v0120.openDb()), dio: Dio()..httpClientAdapter = _BusyGet());
    final r = await service.lookup(const Track(id: 'a', uri: '/m/a.m4a', title: 'The Story of Us', artist: 'milet, someone', durationMs: 267000));
    expect(r?.artist, 'milet');
  });

  group('Japanese songs ask the Japanese store first', () {
    test('by their kana or their lyrics', () async {
      const kana = Track(id: 'a', uri: '/m/a.m4a', title: 'ラブレター', artist: 'x', source: TrackSource.download);
      const kanji = Track(id: 'b', uri: '/m/b.m4a', title: '群青', artist: 'x', source: TrackSource.download);
      Future<String> first(Track t, {bool lyrics = false}) async {
        final it = FakeITunes({});
        await CoverFinder(it, pause: Duration.zero, japaneseLyrics: (_) async => lyrics).find(t);
        return it.asked.first.split(':').first;
      }

      expect(await first(kana), 'JP');
      expect(await first(kanji, lyrics: true), 'JP');
      expect(await first(kanji), ITunesSearch.country);
    });

    test('kana counts, kanji alone does not', () {
      expect(hasKana('恐れずに進め'), isTrue);
      expect(hasKana('群青'), isFalse);
      expect(CoverFinder.storesFor(japanese: true).toSet(), CoverFinder.stores.toSet());
    });
  });

  test('the queue fills its height with whole rows', () {
    for (final height in [64.0, 100.0, 640.0, 741.0]) {
      final rows = height / QueueList.wholeRows(height);
      expect(rows, closeTo(rows.roundToDouble(), 1e-9));
      expect(QueueList.wholeRows(height), inInclusiveRange(64, 128));
    }
    expect(QueueList.wholeRows(741), closeTo(741 / 11, 1e-9));
  });

  group('shortcuts', () {
    final j = PhysicalKeyboardKey.keyJ.usbHidUsage;

    test('the defaults', () {
      expect(actionFor(defaultShortcuts, KeyCombo(j)), AppAction.back);
      expect(actionFor(defaultShortcuts, KeyCombo(j, shift: true)), AppAction.nowPlaying);
      expect(actionFor(defaultShortcuts, KeyCombo(PhysicalKeyboardKey.keyN.usbHidUsage, shift: true)), AppAction.queue);
      expect(actionFor(defaultShortcuts, KeyCombo(j, ctrl: true)), isNull);
      expect(defaultShortcuts.keys.toSet(), AppAction.values.toSet());
      // No key does two things.
      expect(defaultShortcuts.values.toSet().length, AppAction.values.length);
    });

    test('names', () {
      expect(defaultShortcuts[AppAction.queue]!.label, 'Shift+N');
      expect(defaultShortcuts[AppAction.previous]!.label, 'Ctrl+←');
      expect(defaultShortcuts[AppAction.help]!.label, 'Ctrl+/');
    });

    test('a key moved to another action leaves the first one', () {
      final keys = withShortcut(defaultShortcuts, AppAction.mute, KeyCombo(j));
      expect(actionFor(keys, KeyCombo(j)), AppAction.mute);
      expect(keys[AppAction.back], isNull);
    });

    test('未指定 and changes are remembered, the rest keep their defaults', () {
      final keys = withShortcut(withShortcut(defaultShortcuts, AppAction.mute, null), AppAction.home, KeyCombo(j, alt: true));
      final back = decodeShortcuts(encodeShortcuts(keys));
      expect(back[AppAction.mute], isNull);
      expect(back[AppAction.home], KeyCombo(j, alt: true));
      expect(decodeShortcuts('{"mute":null}')[AppAction.search], defaultShortcuts[AppAction.search]);
      expect(decodeShortcuts('not json'), defaultShortcuts);
    });
  });
}
