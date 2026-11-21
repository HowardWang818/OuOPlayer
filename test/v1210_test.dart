// 1.21.0: the Discord status (Windows), its 「Open OuOPlayer」 link that plays
// the song or searches for it, and 新功能 read from the update server.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/config/discord_config.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/discord_presence.dart';
import 'package:ouoplayer/services/listen_link.dart';
import 'package:ouoplayer/services/updater.dart';
import 'package:ouoplayer/ui/pages/onboarding_page.dart' show whatsNewLines;

Track _t(String title, {String artist = 'YOASOBI', int? ms = 258000, String uri = ''}) =>
    Track(id: uri.isEmpty ? title : uri, uri: uri, title: title, artist: artist, album: 'x', durationMs: ms, source: TrackSource.download, addedAt: 1);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Open OuOPlayer link', () {
    test('the page link and the app link carry the song', () {
      final url = ListenLink.webUrl(_t('夜に駆ける'));
      expect(url, startsWith(ListenLink.page));
      final back = ListenLink.parse(url)!;
      expect(back.title, '夜に駆ける');
      expect(back.artist, 'YOASOBI');
      expect(back.durationMs, 258000);
      final app = ListenLink.parse('ouoplayer://play?t=%E7%BE%A4%E9%9D%92&a=YOASOBI&ms=249000')!;
      expect(app.title, '群青');
      expect(app.query, '群青 YOASOBI');
    });

    test('anything else: nothing', () {
      expect(ListenLink.parse('https://example.com/?t=a'), isNull);
      expect(ListenLink.parse('ouoplayer://play'), isNull);
      expect(ListenLink.parse('ouoplayer://other?t=a'), isNull);
      expect(ListenLink.parse(null), isNull);
      expect(ListenLink.fromArgs(['--tray', 'ouoplayer://play?t=a%20b'])!.title, 'a b');
    });

    test('unknown artist is left out of the link', () {
      expect(ListenLink.webUrl(_t('x y', artist: '未知演出者')), isNot(contains('a=')));
    });

    test('the song here plays; one whose file is gone does not count', () {
      final dir = Directory.systemTemp.createTempSync('v1210');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/a.opus')..writeAsStringSync('x');
      final link = ListenLink.parse('ouoplayer://play?t=%E7%BE%A4%E9%9D%92&a=YOASOBI&ms=249000')!;
      expect(link.findIn([_t('群青', ms: 249500, uri: f.path)])?.uri, f.path);
      expect(link.findIn([_t('群青', ms: 249500, uri: '${dir.path}/gone.opus')]), isNull);
      expect(link.findIn([_t('祝福', uri: f.path)]), isNull);
    });

    test('links that come early wait for the app', () {
      final got = <String>[];
      LinkInbox.add('ouoplayer://play?t=a');
      LinkInbox.listen(got.add);
      LinkInbox.add('ouoplayer://play?t=b');
      expect(got, ['ouoplayer://play?t=a', 'ouoplayer://play?t=b']);
    });
  });

  group('Discord status', () {
    test('paused or nothing: cleared', () {
      expect(DiscordActivity.of(_t('a b'), playing: false, position: Duration.zero, nowMs: 0), isNull);
      expect(DiscordActivity.of(null, playing: true, position: Duration.zero, nowMs: 0), isNull);
    });

    test('playing: listening, title, artist, progress, cover, button', () {
      final a = DiscordActivity.of(_t('夜に駆ける'), playing: true, position: const Duration(seconds: 30), nowMs: 1000000)!;
      expect(a['type'], 2);
      expect(a['details'], '夜に駆ける');
      expect(a['state'], 'YOASOBI');
      final ts = a['timestamps']! as Map;
      expect(ts['start'], 1000000 - 30000);
      expect((ts['end'] as int) - (ts['start'] as int), 258000);
      expect((a['assets']! as Map)['large_image'], discordIconUrl);
      final button = (a['buttons']! as List).single as Map;
      expect(button['label'], 'Open OuOPlayer');
      expect(button['url'], startsWith(ListenLink.page));
      final withCover = DiscordActivity.of(_t('夜に駆ける'), playing: true, position: Duration.zero, cover: 'https://x/600x600bb.jpg', nowMs: 0)!;
      expect((withCover['assets']! as Map)['large_image'], 'https://x/600x600bb.jpg');
    });

    test('1.21.1: the member list shows the song', () {
      final a = DiscordActivity.of(_t('春を告げる', artist: 'yama'), playing: true, position: Duration.zero, nowMs: 0)!;
      expect(a['status_display_type'], 2);
    });

    test('1.21.1: five changes at once, then the latest when there is room', () {
      final w = SendWindow();
      final t0 = DateTime(2026, 11, 21, 12);
      for (var i = 0; i < 5; i++) {
        expect(w.wait(t0.add(Duration(seconds: i))), Duration.zero);
        w.sent(t0.add(Duration(seconds: i)));
      }
      expect(w.wait(t0.add(const Duration(seconds: 5))), const Duration(seconds: 15));
      expect(w.wait(t0.add(const Duration(seconds: 20))), Duration.zero, reason: 'the first one has left the 20 seconds');
    });

    test('Discord takes 2 to 128 characters', () {
      final short = DiscordActivity.of(_t('A', artist: '未知演出者'), playing: true, position: Duration.zero, nowMs: 0)!;
      expect((short['details']! as String).length, 2);
      expect(short.containsKey('state'), isFalse);
      final long = DiscordActivity.of(_t('あ' * 200), playing: true, position: Duration.zero, nowMs: 0)!;
      expect((long['details']! as String).runes.length, 128);
    });

    test('a message on the pipe: opcode, length, JSON', () {
      final f = DiscordActivity.frame(1, DiscordActivity.setActivity(null, pid: 42, nonce: '7'));
      final d = ByteData.sublistView(f);
      expect(d.getInt32(0, Endian.little), 1);
      expect(d.getInt32(4, Endian.little), f.length - 8);
      final body = jsonDecode(utf8.decode(f.sublist(8))) as Map;
      expect(body['cmd'], 'SET_ACTIVITY');
      expect((body['args'] as Map)['pid'], 42);
      expect((body['args'] as Map)['activity'], isNull);
    });
  });

  group('新功能 from the update server', () {
    test('its lines come first; without them, the ones in the app', () async {
      expect(await whatsNewLines(online: () async => ['一', '二']), ['一', '二']);
      final bundled = (await rootBundle.loadString('assets/whats_new.txt')).split('\n').where((l) => l.trim().isNotEmpty).length;
      expect((await whatsNewLines(online: () async => null)).length, bundled);
      expect((await whatsNewLines(online: () async => throw 'offline')).length, bundled);
    });

    test('the file', () {
      expect(Updater.parseWhatsNew({'version': '1.21.0', 'lines': ['a', ' ', 'b ']}), ['a', 'b']);
      expect(Updater.parseWhatsNew({'version': '1.21.0'}), isNull);
      expect(Updater.parseWhatsNew(null), isNull);
    });
  });
}
