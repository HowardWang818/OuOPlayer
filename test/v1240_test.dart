// 1.24.0: each playlist (and the liked songs) keeps its own queue, the big
// play button goes on where it was, shuffle stays until tapped again, the
// queue goes on with another round, and synced lists' queues follow the last
// action on any device (never half way through a song). The app's own
// handler, database, list queues and queue sync on a fake player and Drive.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;
// ignore: depend_on_referenced_packages
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/providers/providers.dart';
import 'package:ouoplayer/providers/sync_provider.dart';
import 'package:ouoplayer/services/audio_handler.dart';
import 'package:ouoplayer/services/list_queues.dart';
import 'package:ouoplayer/services/sync2/merge.dart' show songKey;
import 'package:ouoplayer/services/sync2/queue_sync.dart';
import 'package:ouoplayer/ui/pages/collection_page.dart';

import 'sync_scenarios/harness.dart';
import 'v1220_test.dart' show FakePlayer, until;
import 'v1222_test.dart' show TickingPlatform, TickingPlayer;

Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

/// Every player made, in order.
class Players extends TickingPlatform {
  final all = <FakePlayer>[];
  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final p = TickingPlayer(request.id);
    last = p;
    all.add(p);
    return p;
  }
}

const titles = ['a', 'b', 'c', 'd', 'e', 'f'];

/// A device: its library, player, list queues and queue sync.
class Side {
  Side._(this.d, this.h, this.q, this.s);
  final Dev d;
  final OuoAudioHandler h;
  final ListQueues q;
  final QueueSync s;
  late String key;
  FakePlayer? p;

  static Future<Side> make(String name, Cloud cloud, {bool continueAfter = true}) async {
    final d = await Dev.make(name, cloud);
    for (final t in titles) {
      await d.song(t);
    }
    final h = OuoAudioHandler(d.db)
      ..fadeMs = 0
      ..unplayedFirst = false
      ..recordPlays = false
      ..continueAfterQueue = continueAfter;
    await wait(40);
    final q = ListQueues(d.db, h, deviceId: () async => d.id, clock: Clock.tick, random: Random(7));
    await q.ready;
    final s = QueueSync(db: d.db, drive: cloud, deviceId: () async => d.id, queues: q);
    return Side._(d, h, q, s);
  }

  Future<List<Track>> shown() => q.tracksOf(key);
  String? get title => h.currentTrack?.title;
  int get second => h.player.position.inSeconds;
  bool get playing => h.player.playing;
  List<String> get order => [for (final t in h.queueTracks) t.title];

  Future<void> big() async {
    await q.playButton(key, await shown());
    await settleUi();
  }

  Future<void> tap(String title) async {
    final list = await shown();
    await q.playFrom(key, list, list.firstWhere((t) => t.title == title));
    await settleUi();
  }

  Future<void> shuffle() async {
    await q.toggleShuffle(key, await shown());
    await settleUi();
  }

  Future<void> next([int times = 1]) async {
    for (var i = 0; i < times; i++) {
      await h.skipToNext();
      await settleUi();
    }
  }

  Future<void> pause() async {
    await h.pause();
    await settleUi();
  }

  Future<void> sync() async {
    await s.run();
    await settleUi();
  }

  static Future<void> settleUi() => wait(120);

  void dispose() {
    q.dispose();
    unawaited(h.player.pause());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const session = MethodChannel('com.ryanheise.audio_session');
  late Players platform;
  late Cloud cloud;
  final sides = <Side>[];

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(session, (_) async => null);
    platform = Players();
    JustAudioPlatform.instance = platform;
    cloud = Cloud();
    sides.clear();
  });

  tearDown(() async {
    for (final s in sides) {
      s.dispose();
    }
    await wait(80);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(session, null);
  });

  /// One device with the playlist 通勤 (a–f) and another one, 晚上 (a, b).
  Future<Side> one({bool continueAfter = true}) async {
    final side = await Side.make('手機', cloud, continueAfter: continueAfter);
    sides.add(side);
    await side.d.playlist('通勤', [for (final t in titles) await side.d.track(t)]);
    await side.d.playlist('晚上', [await side.d.track('a'), await side.d.track('b')], sync: false);
    side.key = ListQueues.keyFor(await side.d.listId('通勤'));
    return side;
  }

  /// Two devices with 通勤 synced (the second got it from the first).
  Future<(Side, Side)> two() async {
    final phone = await one();
    final pc = await Side.make('電腦', cloud);
    sides.add(pc);
    await settle([phone.d, pc.d]);
    pc.key = ListQueues.keyFor(await pc.d.listId('通勤'));
    return (phone, pc);
  }

  group('規則', () {
    test('同一首歌兩次：第二次有自己的號碼', () {
      final t = Track(id: '1', uri: '1', title: 'A', artist: 'x');
      expect(entryKeys([t, t, Track(id: '2', uri: '2', title: 'B', artist: 'x'), t]), [songKey('A', 'x'), '${songKey('A', 'x')}#2', songKey('B', 'x'), '${songKey('A', 'x')}#3']);
    });

    test('清單加歌：照順序放最後，隨機放在還沒播的部分', () {
      final q = ListQueue(order: ['a', 'b', 'c'], index: 1);
      expect(reconcile(q, ['a', 'b', 'c', 'n']).order, ['a', 'b', 'c', 'n']);
      final s = reconcile(ListQueue(order: ['a', 'b', 'c', 'd'], index: 1, shuffled: true), ['a', 'b', 'c', 'd', 'n'], random: Random(1));
      expect(s.order.indexOf('n'), greaterThan(1));
      expect(s.current, 'b');
    });

    test('清單移除歌：拿掉；正在的那首被移除就到下一首還在的', () {
      final q = ListQueue(order: ['a', 'b', 'c', 'd'], index: 1);
      expect(reconcile(q, ['a', 'c', 'd']).current, 'c');
      final r = reconcile(ListQueue(order: ['a', 'b', 'c', 'd'], index: 2), ['b', 'c', 'd']);
      expect(r.order, ['b', 'c', 'd']);
      expect(r.current, 'c');
    });

    test('最後動作的那台為準；同一刻比裝置', () {
      final a = ListQueue(order: const [], at: 5, device: 'a'), b = ListQueue(order: const [], at: 5, device: 'b');
      expect(b.newerThan(a), isTrue);
      expect(a.newerThan(b), isFalse);
      expect(ListQueue(order: const [], at: 6, device: 'a').newerThan(b), isTrue);
    });

    test('送出的不含秒數', () {
      expect(ListQueue(order: const ['a'], positionMs: 5000).toSync().containsKey('p'), isFalse);
    });
  });

  group('一台', () {
    test('播另一個清單再回來：大播放鍵接著原本的歌、秒數、順序', () async {
      final s = await one();
      await s.big();
      await s.next(2);
      await s.h.seek(const Duration(seconds: 42));
      await Side.settleUi();
      final evening = ListQueues.keyFor(await s.d.listId('晚上'));
      await s.q.playButton(evening, await s.q.tracksOf(evening));
      await Side.settleUi();
      expect(s.title, 'a');
      await s.big();
      expect((s.title, s.second, s.playing), ('c', 42, true));
      expect(s.order, titles);
    });

    test('正在播的清單按大播放鍵：暫停、再按繼續', () async {
      final s = await one();
      await s.big();
      expect(s.playing, isTrue);
      await s.big();
      expect(s.playing, isFalse);
      await s.big();
      expect((s.playing, s.title), (true, 'a'));
    });

    test('點清單裡某一首：從那首開始，順序不變、也記住', () async {
      final s = await one();
      await s.shuffle();
      final shuffled = s.order;
      await s.pause();
      await s.tap('d');
      expect(s.title, 'd');
      expect(s.order, shuffled);
      await s.next();
      final at = s.title;
      final evening = ListQueues.keyFor(await s.d.listId('晚上'));
      await s.q.playButton(evening, await s.q.tracksOf(evening));
      await Side.settleUi();
      await s.big();
      expect(s.title, at);
      expect(s.order, shuffled);
    });

    test('隨機：一直亮著；按掉不改佇列；再按回馬上重新打亂從新的第一首', () async {
      final s = await one();
      await s.big();
      await s.next(2);
      await s.shuffle();
      expect(s.q.shuffledOf(s.key), isTrue);
      expect(s.h.player.currentIndex, 0);
      expect(s.playing, isTrue);
      final first = s.order;
      expect(first.toSet(), titles.toSet());
      await s.next(2);
      final at = s.title;
      await s.shuffle();
      expect(s.q.shuffledOf(s.key), isFalse);
      expect(s.order, first, reason: 'turning it off leaves the queue');
      expect(s.title, at);
      // Another list and back: still off; on again shuffles anew.
      await s.shuffle();
      expect(s.q.shuffledOf(s.key), isTrue);
      expect(s.h.player.currentIndex, 0);
    });

    test('隨機每個清單各自記；換清單再回來還亮著', () async {
      final s = await one();
      await s.shuffle();
      final evening = ListQueues.keyFor(await s.d.listId('晚上'));
      expect(s.q.shuffledOf(evening), isFalse);
      await s.q.playButton(evening, await s.q.tracksOf(evening));
      await Side.settleUi();
      expect(s.q.shuffledOf(s.key), isTrue);
      await s.big();
      expect(s.q.shuffledOf(s.key), isTrue);
    });

    test('播放列的隨機鍵在清單上：一樣的規則', () async {
      final s = await one();
      await s.big();
      await s.next(2);
      await s.h.toggleShuffle();
      await Side.settleUi();
      expect((s.q.shuffledOf(s.key), s.h.player.currentIndex), (true, 0));
      final order = s.order;
      await s.h.toggleShuffle();
      await Side.settleUi();
      expect(s.q.shuffledOf(s.key), isFalse);
      expect(s.order, order);
    });

    test('播完：同一個清單再一輪（照順序從第一首）', () async {
      final s = await one();
      await s.big();
      await s.next(5);
      expect(s.title, 'f');
      (platform.last!).complete();
      await until(() => s.title == 'a' && s.playing, what: 'the next round');
      expect(s.order, titles);
    });

    test('播完：隨機時重新打亂再一輪', () async {
      final s = await one();
      await s.shuffle();
      final first = s.order;
      await s.next(5);
      (platform.last!).complete();
      await until(() => s.h.player.currentIndex == 0 && s.playing && s.order.join() != first.join(),
          what: 'a new shuffled round');
      expect(s.order.toSet(), titles.toSet());
    });

    test('播完：關掉「繼續加歌曲」就停', () async {
      final s = await one(continueAfter: false);
      await s.big();
      await s.next(5);
      (platform.last!).complete();
      await wait(300);
      expect(s.playing, isFalse);
    });

    test('重複播放開著：重複播放為準', () async {
      final s = await one();
      await s.big();
      await s.h.setRepeatMode(AudioServiceRepeatMode.all);
      expect(s.h.player.loopMode, LoopMode.all);
    });

    test('專輯這類不記住的佇列播完：同一份再一輪', () async {
      final s = await one();
      final songs = [await s.d.track('c'), await s.d.track('d')];
      await s.h.playTracks(songs, source: 'album:x');
      await Side.settleUi();
      await s.next();
      (platform.last!).complete();
      await until(() => s.title == 'c' && s.playing, what: 'the album again');
      expect(s.order, ['c', 'd']);
      expect(s.h.queueSource, 'album:x');
    });

    test('清單加歌、移除歌：記住的佇列和正在播的佇列馬上跟著改', () async {
      final s = await one();
      await s.big();
      await s.next();
      final id = await s.d.listId('通勤');
      final g = await s.d.song('g');
      await s.d.db.addToPlaylist(id, [g]);
      await s.d.db.removeTracksFromPlaylist(id, {(await s.d.track('d')).id});
      await until(() => s.order.contains('g') && !s.order.contains('d'), what: 'the queue following the list');
      expect((s.title, s.playing), ('b', true));
      expect(s.order, ['a', 'b', 'c', 'e', 'f', 'g']);
    });

    test('正在播的那首被移出清單：這首播完，之後不再有它', () async {
      final s = await one();
      await s.big();
      await s.next();
      final id = await s.d.listId('通勤');
      await s.d.db.removeTracksFromPlaylist(id, {(await s.d.track('b')).id});
      await wait(800);
      expect((s.title, s.playing), ('b', true));
      await s.next();
      expect(s.title, 'c');
      expect(s.order.skip(s.h.player.currentIndex! + 1), isNot(contains('b')));
      final keys = entryKeys(await s.shown());
      expect(reconcile(s.q[s.key]!, keys).order, isNot(contains(songKey('b', 'A'))));
    });

    test('已按讚的歌曲也記住自己的佇列', () async {
      final s = await one();
      for (final t in ['e', 'b', 'c']) {
        await s.d.like(t);
      }
      final liked = ListQueues.favorites;
      final shown = await s.q.tracksOf(liked);
      await s.q.playButton(liked, shown);
      await Side.settleUi();
      await s.next();
      final at = s.title;
      await s.big();
      await s.q.playButton(liked, await s.q.tracksOf(liked));
      await Side.settleUi();
      expect(s.title, at);
    });

    test('重開 App：記住的佇列還在', () async {
      final s = await one();
      await s.shuffle();
      await s.next(2);
      final order = s.order, at = s.title;
      await s.pause();
      s.q.dispose();
      final again = ListQueues(s.d.db, s.h, deviceId: () async => s.d.id, clock: Clock.tick);
      await again.ready;
      expect(again.shuffledOf(s.key), isTrue);
      expect(again[s.key]!.current, songKey(at!, 'A'));
      expect([for (final k in again[s.key]!.order) k.split('|').first], order);
      again.dispose();
    });

    test('快播完時通知一次，被滑掉前再送一次', () async {
      final s = await one();
      var near = 0, leaving = 0;
      s.h.onNearEnd = () => near++;
      s.h.onLeaving = () async {
        leaving++;
      };
      await s.big();
      await s.h.seek(const Duration(seconds: 190));
      await wait(400);
      expect(near, 1);
      await s.next();
      await s.h.seek(const Duration(seconds: 190));
      await wait(400);
      expect(near, 2);
      await s.h.onTaskRemoved();
      expect(leaving, 1);
    });
  });

  group('兩台', () {
    test('手機播到第 5 首暫停；電腦按大播放鍵從第 6 首開始', () async {
      final (phone, pc) = await two();
      await phone.big();
      await phone.next(4);
      expect(phone.title, 'e');
      await phone.pause();
      await phone.sync();
      await pc.sync();
      await pc.big();
      expect((pc.title, pc.second), ('f', 0));
    });

    test('電腦正在播第 2 首：播完接手機那邊的下一首', () async {
      final (phone, pc) = await two();
      await pc.big();
      await pc.next();
      expect(pc.title, 'b');
      await pc.sync();
      await phone.big();
      await phone.next(4);
      await phone.pause();
      await phone.sync();
      await pc.sync();
      expect((pc.title, pc.playing), ('b', true), reason: 'the song playing goes on');
      await pc.next();
      expect(pc.title, 'f');
    });

    test('隨機和順序都跟著最後動作的那台', () async {
      final (phone, pc) = await two();
      await phone.shuffle();
      final order = phone.order;
      await phone.pause();
      await phone.sync();
      await pc.sync();
      expect(pc.q.shuffledOf(pc.key), isTrue);
      await pc.big();
      expect(pc.order, order);
      expect(pc.title, order[1]);
    });

    test('兩台都動過：後動作的為準', () async {
      final (phone, pc) = await two();
      await phone.big();
      await phone.next();
      await phone.pause();
      await pc.big();
      await pc.next(3);
      await pc.pause();
      await phone.sync();
      await pc.sync();
      await phone.sync();
      expect(phone.q[phone.key]!.current, songKey('e', 'A'));
      expect(pc.q[pc.key]!.current, songKey('d', 'A'));
    });

    test('同步完再同步：雲端不再寫入', () async {
      final (phone, pc) = await two();
      await phone.big();
      await phone.next(2);
      await phone.pause();
      for (var i = 0; i < 2; i++) {
        await phone.sync();
        await pc.sync();
      }
      final before = cloud.fingerprint;
      for (var i = 0; i < 3; i++) {
        await phone.sync();
        await pc.sync();
      }
      expect(cloud.fingerprint, before);
    });

    test('沒勾同步的清單：只記在這台', () async {
      final (phone, pc) = await two();
      // Synced once and then not (停止同步): it has an id in sync, still not sent.
      await phone.d.engine.enable(await phone.d.listId('晚上'));
      await phone.d.engine.disable(await phone.d.listId('晚上'));
      final evening = ListQueues.keyFor(await phone.d.listId('晚上'));
      await phone.q.playButton(evening, await phone.q.tracksOf(evening));
      await Side.settleUi();
      await phone.pause();
      await phone.sync();
      final file = cloud.files.values.firstWhere((f) => f.$1 == 'v2-queues-手機.json');
      final lists = (jsonDecode(utf8.decode(file.$2)) as Map)['lists'] as Map;
      expect(lists, isEmpty, reason: '晚上 is not synced');
      expect(pc.q.all.length, lessThanOrEqualTo(1));
    });

    test('只在一台有的歌：另一台略過', () async {
      final (phone, pc) = await two();
      final only = await phone.d.song('z');
      await phone.d.db.addToPlaylist(await phone.d.listId('通勤'), [only]);
      await phone.tap('z');
      await phone.next();
      await phone.pause();
      await phone.sync();
      await pc.sync();
      await pc.big();
      expect(pc.order.contains('z'), isFalse);
      expect(pc.title, isNotNull);
    });

    test('1.23.0 留下的接續播放檔：刪掉', () async {
      final (phone, _) = await two();
      await cloud.upload('v2-now-手機.json', utf8.encode('{}'));
      await phone.sync();
      expect(cloud.count('v2-now-'), 0);
    });
  });

  group('沒畫面時按播放', () {
    test('先同步再播（最多等 2 秒）', () async {
      final (phone, pc) = await two();
      await pc.big();
      await pc.pause();
      await phone.big();
      await phone.next(2);
      await phone.pause();
      await phone.sync();
      var asked = 0;
      pc.h.beforePlay = (cancelled, deadline) async {
        asked++;
        await pc.s.run();
      };
      unawaited(pc.h.play());
      await wait(400);
      expect((asked, pc.title, pc.playing), (1, 'd', true));
    });
  });

  group('裝置名稱', () {
    test('改了名字：另一台看到新名字', () async {
      final phone = await Dev.make('手機', cloud, id: 'phone');
      final pc = await Dev.make('電腦', cloud, id: 'pc');
      final a = await phone.song('a');
      await phone.playlist('L', [a]);
      await settle([phone, pc]);
      phone.engine.deviceName = '手機（SM-S7110）';
      await phone.sync();
      final state = cloud.files.values.firstWhere((f) => f.$1 == 'v2-state-phone.json');
      expect((jsonDecode(utf8.decode(state.$2)) as Map)['name'], '手機（SM-S7110）');
      await expectStable([phone, pc]);
    });

    test('沒取名：手機（型號）／電腦（電腦名稱）', () async {
      final db = (await Dev.make('x', cloud)).db;
      expect(await deviceNameOf(db), startsWith('電腦（'));
      await db.setSetting(deviceNameKey, '  書房  ');
      expect(await deviceNameOf(db), '書房');
    });
  });

  group('大播放鍵的圖示', () {
    testWidgets('這份清單在播：暫停；播別的或停著：播放', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(session, (_) async => null);
      late Side s;
      late ProviderContainer c;
      await tester.runAsync(() async {
        s = await one();
        c = ProviderContainer(overrides: [
          dbProvider.overrideWithValue(s.d.db),
          audioHandlerProvider.overrideWithValue(s.h),
          listQueuesProvider.overrideWithValue(s.q),
          currentTrackProvider.overrideWithValue(null),
          playlistSyncedProvider.overrideWith((ref, id) async => false),
        ]);
      });
      final id = await tester.runAsync(() => s.d.listId('通勤'));
      await tester.pumpWidget(UncontrolledProviderScope(container: c, child: MaterialApp(home: CollectionPage.playlist(id!, '通勤'))));
      Future<void> frames() async {
        for (var i = 0; i < 5; i++) {
          await tester.runAsync(() => wait(60));
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await frames();
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      await tester.runAsync(s.big);
      await frames();
      expect(find.byIcon(Icons.pause), findsOneWidget);
      await tester.runAsync(s.pause);
      await frames();
      expect(find.byIcon(Icons.pause), findsNothing);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  });
}
