// 1.23.0: two devices that played apart both keep their progress. Two whole
// apps here (handler, database, sync provider, dialogs) on a fake Drive,
// player and clock.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:ouoplayer/app.dart' show rootNavigatorKey;
import 'package:ouoplayer/providers/auto_backup_provider.dart';
import 'package:ouoplayer/services/auto_backup.dart';
import 'package:ouoplayer/ui/widgets/backup_cleanup.dart';
import 'package:ouoplayer/data/db/database.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/providers/providers.dart';
import 'package:ouoplayer/providers/sync_provider.dart';
import 'package:ouoplayer/services/audio_handler.dart';
import 'package:ouoplayer/services/backup.dart';
import 'package:ouoplayer/services/library_scanner.dart';
import 'package:ouoplayer/services/network_check.dart';
import 'package:ouoplayer/services/sync/drive_client.dart';
import 'package:ouoplayer/services/sync2/now_playing.dart';

import 'sync_scenarios/harness.dart';
import 'v0120_test.dart' show openDb;
import 'v1222_test.dart' show TickingPlatform;

Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

class SlowCloud extends Cloud {
  /// Each v2-now upload waits the next of these.
  final delays = <int>[];

  /// Reading the folder takes this long.
  int listMs = 0;

  @override
  Future<String> upload(String name, List<int> bytes, {String? id, String mime = ''}) async {
    if (name.startsWith('v2-now-') && delays.isNotEmpty) await wait(delays.removeAt(0));
    return super.upload(name, bytes, id: id, mime: mime);
  }

  @override
  Future<List<DriveFile>> list() async {
    if (listMs > 0) await wait(listMs);
    return super.list();
  }
}

/// Stores covers in [dir] (the app's own folder needs the platform).
class CoverScanner extends LibraryScanner {
  CoverScanner(super.db, this.dir);
  final Directory dir;

  @override
  Future<String> storeArt(Uint8List bytes, String mime) async =>
      (File('${dir.path}/stored_${bytes.length}.jpg')..writeAsBytesSync(bytes)).path;
}

/// One wall clock for both devices, moved by hand while they 「play」.
class Wall {
  DateTime now = DateTime.now();
  void pass(Duration d) => now = now.add(d);
}

class App {
  App(this.d, this.wall, {this.fakeScreen = true});
  final Dev d;
  final Wall wall;

  /// False: the app's own answer to 「is there a screen」.
  final bool fakeScreen;
  bool onScreen = true;
  late OuoAudioHandler h;
  late ProviderContainer c;
  SyncNotifier get n => c.read(syncProvider.notifier);

  Future<void> open({bool triggers = false}) async {
    h = OuoAudioHandler(d.db)
      ..fadeMs = 0
      ..unplayedFirst = false
      ..continueAfterQueue = false;
    await wait(60);
    await h.restoreSession();
    c = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(d.db),
      audioHandlerProvider.overrideWithValue(h),
      syncEngineProvider.overrideWithValue(d.engine),
      resumeClockProvider.overrideWithValue(() => wall.now),
      if (fakeScreen) appOnScreenProvider.overrideWithValue(() async => onScreen),
    ]);
    c.read(syncProvider);
    await c.read(resumeTrackerProvider).ready;
    await wait(80);
    h.beforePlay = (cancelled, deadline) => n.beforePlay(cancelled, deadline);
    if (triggers) c.read(syncTriggersProvider);
  }

  Future<void> close() async {
    await h.player.pause();
    await wait(250);
    c.dispose();
  }

  Future<void> start(List<String> titles) async {
    await h.playTracks([for (final t in titles) await d.track(t)]);
    await wait(150);
  }

  /// [seconds] go by while it plays.
  Future<void> goOn(int seconds) async {
    final to = h.player.position + Duration(seconds: seconds);
    for (var left = seconds; left > 0; left -= 60) {
      wall.pass(Duration(seconds: left > 60 ? 60 : left));
      await h.saveSession();
    }
    await h.seek(to);
    await wait(100);
  }

  Future<void> pause() async {
    await h.pause();
    await wait(120);
    await n.pushNowPlaying();
  }

  /// Plays [titles] from [from] for [seconds], then pauses.
  Future<void> listen(List<String> titles, int seconds, {int from = 0}) async {
    await start(titles);
    await h.seek(Duration(seconds: from));
    await goOn(seconds);
    await pause();
  }

  String? get title => h.currentTrack?.title;
  int get second => h.player.position.inSeconds;
  bool get playing => h.player.playing;

  Future<void> expectAt(String song, int at, {bool isPlaying = false}) async {
    await wait(80);
    expect(title, song, reason: d.name);
    expect(second, closeTo(at, 1.5), reason: d.name);
    expect(playing, isPlaying, reason: d.name);
  }
}

/// (song, second) of [device]'s file on Drive, null without one.
(String, int)? onDrive(Cloud cloud, String device) {
  for (final f in cloud.files.values) {
    if (f.$1 != 'v2-now-$device.json') continue;
    final n = NowPlaying.fromJson(jsonDecode(utf8.decode(f.$2)) as Map)!;
    return ('${n.current['t']}', (n.positionMs / 1000).floor());
  }
  return null;
}

/// About [second] of [song].
Matcher around(String song, int second) => predicate<(String, int)?>(
    (v) => v != null && v.$1 == song && (v.$2 - second).abs() <= 1, '$song at about $second s');

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => debugSyncAvailable = true);
  tearDown(() => debugSyncAvailable = null);

  group('判斷', () {
    final now = DateTime(2026, 11, 22, 20);
    int ago(Duration d) => now.subtract(d).millisecondsSinceEpoch;
    NowPlaying from(String device,
            {int mark = 90000, int? at, Map<String, int> seen = const {}, String session = 's', bool playing = false, bool over = false}) =>
        NowPlaying(
            device: device,
            deviceName: device,
            at: at ?? ago(const Duration(minutes: 5)),
            songs: const [{'t': 'a', 'a': 'A'}],
            index: 0,
            positionMs: mark,
            mark: mark,
            seen: seen,
            session: session,
            playing: playing,
            over: over);
    ResumeState played(int ms, {int? at}) => ResumeState()..heard(ms, at ?? ago(const Duration(minutes: 1)));
    ResumePlan plan(List<NowPlaying> others, ResumeState state, {ResumeMode mode = ResumeMode.auto, bool playing = false}) =>
        resumePlan(mode: mode, others: others, me: 'me', state: state, now: now, playingHere: playing);

    test('不到 30 秒不算；累計到 30 秒全部算進去', () {
      final s = ResumeState()..heard(12000, 1);
      expect((s.mark, s.counts), (0, false));
      s.heard(12000, 2);
      expect((s.mark, s.counts), (0, false));
      s.heard(12000, 3);
      expect((s.mark, s.counts, s.at), (36000, true, 3));
      s.heard(1000, 4);
      expect(s.mark, 37000);
    });

    test('另一台播不到 30 秒：不是較新', () {
      expect(plan([from('b', mark: 29999)], ResumeState()).step, ResumeStep.none);
      expect(plan([from('b', mark: 30000)], ResumeState()).step, ResumeStep.load);
    });

    test('這台播不到 30 秒：還是跟著另一台', () {
      expect(plan([from('b')], ResumeState()..heard(29000, 1)).step, ResumeStep.load);
    });

    test('都播過：不比誰晚', () {
      for (final age in [const Duration(minutes: 1), const Duration(hours: 3)]) {
        expect(plan([from('b', at: ago(age))], played(40000)).step, ResumeStep.choose);
        expect(plan([from('b')], played(40000, at: ago(age))).step, ResumeStep.choose);
      }
    });

    test('對方處理過這台的：只有對方播過', () {
      expect(plan([from('b', seen: {'me': 40000})], played(40000)).step, ResumeStep.load);
    });

    test('時鐘不準也一樣', () {
      final late = from('b', at: ago(const Duration(hours: 5)), seen: {'me': 40000});
      expect(plan([late], played(40000)).step, ResumeStep.load);
      final early = from('b', at: now.add(const Duration(hours: 2)).millisecondsSinceEpoch);
      expect(plan([early], played(40000)).step, ResumeStep.choose);
    });

    test('這台播的已超過 12 小時：不算都播過', () {
      expect(plan([from('b')], played(40000, at: ago(const Duration(hours: 13)))).step, ResumeStep.load);
    });

    test('另一台的超過 12 小時：不問', () {
      final p = plan([from('b', at: ago(const Duration(hours: 13)))], ResumeState());
      expect(p.step, ResumeStep.none);
      expect(p.expired.single.device, 'b');
      expect(p.why, startsWith('older than 12 h'));
    });

    test('被放棄的進度：不問', () {
      expect(plan([from('b', over: true)], ResumeState()).step, ResumeStep.none);
    });

    test('播放中：不問，記著有另一個', () {
      final p = plan([from('b')], played(40000), playing: true);
      expect((p.step, p.both), (ResumeStep.none, true));
    });

    test('不接續：什麼都不做', () {
      expect(plan([from('b')], ResumeState(), mode: ResumeMode.never).step, ResumeStep.none);
    });

    test('跟著的那台又播幾秒、這台之後也播過：不算都播過', () {
      final state = ResumeState()..settle(from('b', mark: 90000), took: true);
      expect(plan([from('b', mark: 95000)], state).step, ResumeStep.load);
      state.heard(40000, ago(const Duration(minutes: 1)));
      expect(plan([from('b', mark: 95000)], state).step, ResumeStep.none);
    });

    test('三台：被接走的那份不再列出', () {
      final p = plan([from('b'), from('c', mark: 50000, seen: {'b': 90000}, session: 't')], ResumeState());
      expect((p.step, p.offers.single.device), (ResumeStep.load, 'c'));
    });

    test('三台：互相沒看過的都列出', () {
      final p = plan([from('b'), from('c', session: 't')], ResumeState());
      expect((p.step, p.offers.length), (ResumeStep.choose, 2));
    });

    test('存下再讀回來一樣', () {
      final s = played(40000)
        ..session = 's1'
        ..settle(from('b'), took: true)
        ..quiet['c'] = 'x';
      expect(jsonEncode(ResumeState.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map).toJson()), jsonEncode(s.toJson()));
      final n = from('b', seen: {'me': 5}, playing: true);
      expect(jsonEncode(NowPlaying.fromJson(jsonDecode(jsonEncode(n.toJson())) as Map)!.toJson()), jsonEncode(n.toJson()));
    });
  });

  group('兩台', () {
    late WidgetTester t;
    late SlowCloud cloud;
    late Wall wall;
    late List<App> apps;

    void both(String name, Future<void> Function() body) {
      testWidgets(name, (tester) async {
        t = tester;
        cloud = SlowCloud();
        wall = Wall();
        apps = [];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('com.ryanheise.audio_session'), (_) async => null);
        await tester.pumpWidget(MaterialApp(navigatorKey: rootNavigatorKey, home: const Scaffold()));
        await tester.runAsync(() async {
          JustAudioPlatform.instance = TickingPlatform();
          await body();
          for (final a in apps) {
            await a.close();
          }
        });
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 6));
      });
    }

    Future<App> device(String name, {String mode = 'ask', bool triggers = false, bool fakeScreen = true}) async {
      final d = await Dev.make(name, cloud);
      for (final s in ['a', 'b', 'c', 'd']) {
        await d.song(s);
      }
      await d.set('sync_signed_in', 'true');
      await d.set('sync_resume_mode', mode);
      final app = App(d, wall, fakeScreen: fakeScreen);
      await app.open(triggers: triggers);
      apps.add(app);
      return app;
    }

    Future<void> frames() async {
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
    }

    /// The question [title] up (or not, after a moment).
    Future<bool> shown(String title) async {
      for (var i = 0; i < 20; i++) {
        await wait(50);
        await frames();
        if (find.text(title).evaluate().isNotEmpty) return true;
      }
      return false;
    }

    Future<void> tap(String text) async {
      await t.tap(find.text(text).last);
      await frames();
    }

    const one = '要接著播嗎？', which = '要從哪裡接著播？';

    /// Checks [a]; expects [title] and answers it with [taps].
    Future<void> answer(App a, String title, List<String> taps) async {
      final done = a.n.offerResume();
      expect(await shown(title), isTrue, reason: '${a.d.name}: $title');
      for (final text in taps) {
        await tap(text);
      }
      await done;
      await frames();
      await wait(150);
    }

    /// Checks [a]; nothing is asked.
    Future<void> quiet(App a) async {
      await a.n.offerResume().timeout(const Duration(seconds: 3));
      await frames();
      expect(find.text(one), findsNothing);
      expect(find.text(which), findsNothing);
    }

    both('B 先播了：播放中不問，暫停時列出兩個；選 A 就從 1:31', () async {
      final a = await device('A');
      await a.listen(['a', 'b'], 91);
      final b = await device('B');
      await b.start(['a', 'b']);
      await b.h.seek(const Duration(seconds: 30));
      await b.goOn(39);
      await quiet(b);
      expect(await b.d.setting('sync_resume_debug'), contains('two: playing here'));
      await b.pause();

      final done = b.n.offerResume();
      expect(await shown(which), isTrue);
      expect(find.text('1:31'), findsOneWidget);
      expect(find.text('1:09'), findsOneWidget);
      expect(find.text('這台'), findsOneWidget);
      await tap('A');
      await tap('接著播');
      await done;
      await b.expectAt('a', 91);
      await quiet(b);
    });

    both('選這台：A 之後跟著 B，不再兩邊互問', () async {
      final a = await device('A', mode: 'auto');
      await a.listen(['a', 'b'], 91);
      final b = await device('B');
      await b.listen(['c', 'd'], 45);
      await answer(b, which, ['接著播']);
      await b.expectAt('c', 45);
      await b.n.pushNowPlaying();
      await quiet(a);
      await a.expectAt('c', 45);
      await quiet(b);
      await quiet(a);
    });

    both('選另一台：A 不會被換成 B 放棄的那份', () async {
      final a = await device('A', mode: 'auto');
      await a.listen(['a', 'b'], 91);
      final b = await device('B');
      await b.listen(['c', 'd'], 45);
      await answer(b, which, ['A', '接著播']);
      await b.n.pushNowPlaying();
      await quiet(a);
      await a.expectAt('a', 91);
    });

    both('取消：都不動、不再問；設定裡還能選', () async {
      final a = await device('A');
      await a.listen(['a', 'b'], 91);
      final b = await device('B');
      await b.listen(['c', 'd'], 45);
      await answer(b, which, ['取消']);
      await b.expectAt('c', 45);
      await quiet(b);
      expect(await b.d.setting('sync_resume_debug'), contains('already asked (two)'));
      final done = b.n.chooseProgress(rootNavigatorKey.currentContext!);
      expect(await shown(which), isTrue);
      await tap('A');
      await tap('接著播');
      await done;
      await b.expectAt('a', 91);
    });

    both('自動接續：A 沒網路時播過，不會被 B 蓋掉', () async {
      final a = await device('A', mode: 'auto');
      final b = await device('B', mode: 'never');
      cloud.offline = true;
      await a.listen(['a', 'b'], 91);
      expect(a.n.nowPending, isTrue);
      cloud.offline = false;
      await b.listen(['c', 'd'], 40);
      await a.n.pushNowPlaying();
      await answer(a, which, ['取消']);
      await a.expectAt('a', 91);
      expect(onDrive(cloud, 'A'), around('a', 91));
    });

    both('自動接續換掉的：雲端那份沒被蓋，設定裡換得回來', () async {
      final a = await device('A', mode: 'auto');
      await a.listen(['a', 'b'], 91);
      wall.pass(const Duration(hours: 13));
      final b = await device('B');
      await b.listen(['c', 'd'], 40);
      await quiet(a);
      await a.expectAt('c', 40);
      await a.n.pushNowPlaying();
      expect(onDrive(cloud, 'A'), around('a', 91));
      final done = a.n.chooseProgress(rootNavigatorKey.currentContext!);
      expect(await shown(which), isTrue);
      expect(find.text('這台（先前）'), findsOneWidget);
      await tap('這台（先前）');
      await tap('接著播');
      await done;
      await a.expectAt('a', 91);
    });

    both('只按 1 秒：誰的進度都不動', () async {
      final a = await device('A', mode: 'auto');
      await a.listen(['a', 'b'], 190);
      final b = await device('B', mode: 'never');
      await b.listen(['c'], 1);
      await quiet(a);
      await a.expectAt('a', 190);
      expect(onDrive(cloud, 'B'), isNull);
    });

    both('聽過很久再誤按一下：送出的還是很久的那份', () async {
      final b = await device('B');
      await b.listen(['d'], 150);
      await b.listen(['c'], 1);
      expect(onDrive(cloud, 'B'), around('d', 150));
    });

    both('試幾首各 12 秒：累計到 30 秒算', () async {
      final b = await device('B');
      await b.listen(['a'], 12);
      await b.listen(['b'], 12);
      expect(onDrive(cloud, 'B'), isNull);
      await b.listen(['c'], 12);
      expect(onDrive(cloud, 'B'), around('c', 12));
    });

    both('一台播完換一台：自動接續一路跟著，不用選', () async {
      final a = await device('A', mode: 'auto');
      final b = await device('B', mode: 'auto');
      await a.listen(['a', 'b'], 60);
      await quiet(b);
      await b.expectAt('a', 60);
      unawaited(b.h.play());
      await wait(150);
      await b.goOn(50);
      await b.pause();
      await quiet(a);
      await a.expectAt('a', 110);
      unawaited(a.h.play());
      await wait(150);
      await a.goOn(40);
      await a.pause();
      await quiet(b);
      await b.expectAt('a', 150);
    });

    both('自動接續還在播的：停在哪就跟到哪', () async {
      final a = await device('A');
      final b = await device('B', mode: 'auto');
      await a.start(['a', 'b']);
      await a.goOn(60);
      await a.n.pushNowPlaying();
      await quiet(b);
      await b.expectAt('a', 60);
      await a.goOn(10);
      await a.pause();
      await quiet(b);
      await b.expectAt('a', 70);
    });

    both('按「不要」：A 一直播也不再問；A 之後再播才問', () async {
      final a = await device('A');
      final b = await device('B');
      await a.start(['a', 'b']);
      await a.goOn(40);
      await a.n.pushNowPlaying();
      await answer(b, one, ['不要']);
      for (var minute = 0; minute < 3; minute++) {
        await a.goOn(20);
        await a.n.pushNowPlaying();
        await quiet(b);
      }
      await a.pause();
      await quiet(b);
      wall.pass(const Duration(minutes: 5));
      await a.listen(['c'], 40);
      await answer(b, one, ['不要']);
    });

    both('按「接著播」：A 還在播時不重問，停了再問', () async {
      final a = await device('A');
      final b = await device('B');
      await a.start(['a', 'b']);
      await a.goOn(40);
      await a.n.pushNowPlaying();
      await answer(b, one, ['接著播']);
      await b.expectAt('a', 40);
      await a.goOn(50);
      await a.n.pushNowPlaying();
      await quiet(b);
      await a.pause();
      await answer(b, one, ['接著播']);
      await b.expectAt('a', 90);
    });

    both('詢問開著時按播放：視窗關掉、不跳歌、照常記錄，暫停再問', () async {
      final a = await device('A');
      await a.listen(['a', 'b'], 91);
      final b = await device('B');
      final done = b.n.offerResume();
      expect(await shown(one), isTrue);
      await b.start(['c', 'd']);
      await frames();
      await done.timeout(const Duration(seconds: 3));
      expect(find.text(one), findsNothing);
      expect((b.title, b.playing), ('c', true));
      expect((await b.d.db.db.query('listening_log')).length, 1);
      await b.pause();
      await answer(b, one, ['不要']);
    });

    both('在設定裡選：先暫停再換，之後播的照常記錄', () async {
      final a = await device('A');
      await a.listen(['a', 'b'], 91);
      final b = await device('B');
      await b.start(['c', 'd']);
      final done = b.n.chooseProgress(rootNavigatorKey.currentContext!);
      expect(await shown(which), isTrue);
      await tap('A');
      await tap('接著播');
      await done;
      await b.expectAt('a', 91);
      unawaited(b.h.play());
      await wait(300);
      final logged = [for (final r in await b.d.db.db.query('listening_log')) r['track_id']];
      expect(logged.toSet(), {(await b.d.track('a')).id, (await b.d.track('c')).id});
    });

    both('沒傳出去就關掉：下次開啟時補傳', () async {
      final a = await device('A');
      cloud.offline = true;
      await a.listen(['a', 'b'], 91);
      await a.h.saveSession();
      await a.close();
      cloud.offline = false;
      await a.open(triggers: true);
      expect(a.n.nowPending, isTrue);
      await wait(9000);
      expect(onDrive(cloud, 'A'), around('a', 91));
    });

    both('接了另一台的進度、只播幾秒：雲端上這台的還是自己原本的', () async {
      final a = await device('A');
      final b = await device('B', mode: 'auto');
      await b.listen(['c', 'd'], 45);
      wall.pass(const Duration(hours: 13));
      await a.listen(['a', 'b'], 91);
      await quiet(b);
      await b.expectAt('a', 91);
      unawaited(b.h.play());
      await wait(150);
      await b.goOn(5);
      await b.pause();
      expect(onDrive(cloud, 'B'), around('c', 45));
      unawaited(b.h.play());
      await wait(150);
      await b.goOn(30);
      await b.pause();
      expect(onDrive(cloud, 'B'), around('a', 126));
    });

    both('舊的上傳比較慢：最後留在雲端的是新的', () async {
      final a = await device('A');
      await a.start(['a', 'b']);
      await a.goOn(35);
      // Its file is on Drive already: both uploads write that one.
      await a.n.pushNowPlaying();
      await a.goOn(5);
      cloud.delays.addAll([700, 0]);
      final first = a.n.pushNowPlaying();
      await wait(80);
      await a.goOn(50);
      await a.n.pushNowPlaying();
      await first;
      await wait(800);
      expect(cloud.count('v2-now-A'), 1);
      expect(onDrive(cloud, 'A'), around('a', 90));
    });

    both('背景啟動：不開看不見的視窗、不換佇列；打開後才問', () async {
      final a = await device('A');
      await a.listen(['a', 'b'], 91);
      binding.resetInternalState();
      for (final mode in ['ask', 'auto']) {
        final b = await device('B-$mode', mode: mode, fakeScreen: false);
        await quiet(b);
        expect(b.title, isNull);
        expect(await b.d.setting('sync_resume_debug'), contains('not on screen'));
        await b.close();
        apps.remove(b);
        final opened = App(b.d, wall);
        await opened.open();
        apps.add(opened);
        if (mode == 'ask') {
          await answer(opened, one, ['不要']);
        } else {
          await quiet(opened);
          await opened.expectAt('a', 91);
        }
      }
    });

    both('背景播放＋自動接續：從 A 那裡播', () async {
      final a = await device('A');
      await a.listen(['a', 'b'], 91);
      final b = await device('B', mode: 'auto');
      b.onScreen = false;
      unawaited(b.h.play());
      await wait(600);
      expect((b.title, b.playing), ('a', true));
      expect(b.second, inInclusiveRange(90, 93));
    });

    both('背景播放＋每次詢問：立刻播這台的，不等', () async {
      final b = await device('B');
      await b.listen(['c'], 5);
      final a = await device('A');
      await a.listen(['a', 'b'], 91);
      cloud.listMs = 5000;
      b.onScreen = false;
      unawaited(b.h.play());
      await wait(300);
      expect((b.title, b.playing), ('c', true));
    });

    both('背景播放＋不接續：立刻播這台的', () async {
      final b = await device('B', mode: 'never');
      await b.listen(['c'], 5);
      final a = await device('A');
      await a.listen(['a', 'b'], 91);
      cloud.listMs = 5000;
      b.onScreen = false;
      unawaited(b.h.play());
      await wait(300);
      expect((b.title, b.playing), ('c', true));
    });

    both('背景播放＋兩台都播過：播這台的，打開暫停時選', () async {
      final a = await device('A');
      final b = await device('B', mode: 'auto');
      await b.listen(['c', 'd'], 45);
      await a.listen(['a', 'b'], 91);
      b.onScreen = false;
      unawaited(b.h.play());
      await wait(600);
      expect((b.title, b.playing), ('c', true));
      await b.pause();
      await quiet(b);
      b.onScreen = true;
      await answer(b, which, ['A', '接著播']);
      await b.expectAt('a', 91);
    });

    both('背景播放查不到：2 秒後播這台的，晚到的答案不會跳歌', () async {
      final b = await device('B', mode: 'auto');
      await b.listen(['c'], 5);
      final a = await device('A');
      await a.listen(['a', 'b'], 91);
      cloud.listMs = 3000;
      b.onScreen = false;
      unawaited(b.h.play());
      await wait(700);
      expect(b.playing, isFalse);
      // Told at once: the notification is up and pause works.
      expect(b.h.playbackState.value.playing, isTrue);
      await wait(1700);
      expect((b.title, b.playing), ('c', true));
      await wait(1500);
      expect((b.title, b.playing), ('c', true));
    });

    both('等的時候按暫停：不播、不換', () async {
      final b = await device('B', mode: 'auto');
      await b.listen(['c'], 5);
      final a = await device('A');
      await a.listen(['a', 'b'], 91);
      cloud.listMs = 900;
      b.onScreen = false;
      unawaited(b.h.play());
      await wait(200);
      await b.h.pause();
      await wait(1300);
      expect((b.title, b.playing, b.h.playbackState.value.playing), ('c', false, false));
    });

    both('等的時候自己選歌：播選的', () async {
      final b = await device('B', mode: 'auto');
      await b.listen(['c'], 5);
      final a = await device('A');
      await a.listen(['a', 'b'], 91);
      cloud.listMs = 900;
      b.onScreen = false;
      unawaited(b.h.play());
      await wait(200);
      await b.start(['d']);
      await wait(1300);
      expect((b.title, b.playing), ('d', true));
    });

    both('等的時候再按一次播放：只播一次', () async {
      final b = await device('B', mode: 'auto');
      await b.listen(['c'], 5);
      final a = await device('A');
      await a.listen(['a', 'b'], 91);
      cloud.listMs = 500;
      b.onScreen = false;
      unawaited(b.h.play());
      await wait(100);
      unawaited(b.h.play());
      await wait(900);
      expect((b.title, b.playing), ('a', true));
      await b.pause();
      expect(b.playing, isFalse);
    });

    both('冷啟動：按播放比 providers 早，也會等', () async {
      final a = await device('A');
      await a.listen(['a', 'b'], 91);
      final b = await device('B', mode: 'auto');
      b.onScreen = false;
      final hook = b.h.beforePlay;
      b.h
        ..beforePlay = null
        ..expectBeforePlay();
      unawaited(b.h.play());
      await wait(300);
      expect(b.playing, isFalse);
      b.h.beforePlay = hook;
      await wait(600);
      expect((b.title, b.playing), ('a', true));
    });

    both('畫面開著按播放：播畫面上的', () async {
      final b = await device('B', mode: 'auto');
      await b.listen(['c'], 5);
      final a = await device('A');
      await a.listen(['a', 'b'], 91);
      unawaited(b.h.play());
      await wait(300);
      expect((b.title, b.playing), ('c', true));
    });

    both('暫停、畫面開著：自己問', () async {
      final a = await device('A');
      await a.listen(['a', 'b'], 91);
      final b = await device('B', triggers: true);
      await b.start(['c', 'd']);
      await b.goOn(40);
      await b.h.pause();
      await wait(1200);
      expect(await shown(which), isTrue);
      await tap('取消');
      await wait(100);
    });
  });

  group('收聽秒數', () {
    test('15 → 16：舊紀錄留著，分不開的照舊', () async {
      final app = await openDb();
      await app.db.execute('DROP TABLE listening_log');
      await app.db.execute('CREATE TABLE listening_log(id INTEGER PRIMARY KEY, track_id TEXT, played_at INTEGER, listened_ms INTEGER, '
          'source TEXT, estimated INTEGER DEFAULT 0, origin TEXT, remote_id TEXT)');
      await app.db.insert('listening_log', {'track_id': 'x', 'played_at': 1, 'listened_ms': 7000});
      await AppDatabase.migrate(app.db, 15, 16);
      final row = (await app.db.query('listening_log')).single;
      expect((row['listened_ms'], row['parts']), (7000, null));
    });

    test('還原到同一台、新裝的：都不會算兩次', () async {
      final cloud = Cloud();
      final a = await Dev.make('A', cloud);
      final b = await Dev.make('B', cloud);
      await a.song('a');
      await b.song('a');
      final began = await a.play('a', seconds: 60);
      await settle([a, b]);
      await b.carryOn('a', began, 60000, seconds: 40, parts: {'A': 60000});
      await settle([a, b]);
      expect(await a.heard('a'), [100]);

      final dir = await Directory.systemTemp.createTemp('ouo_parts');
      final backup = jsonDecode(jsonEncode(await buildBackup(a.db, lyricsDir: dir))) as Map<String, dynamic>;
      await restoreBackup(a.db, LibraryScanner(a.db), backup, coverDir: dir, lyricsDir: dir, parts: {RestorePart.history});
      await settle([a, b]);
      expect(await a.heard('a'), [100]);
      expect(await b.heard('a'), [100]);
      await expectStable([a, b]);

      final again = await a.reinstall();
      await restoreBackup(again.db, LibraryScanner(again.db), backup, coverDir: dir, lyricsDir: dir, parts: {RestorePart.history});
      await settle([again, b]);
      expect(await again.heard('a'), [100]);
      expect(await b.heard('a'), [100]);
      await expectStable([again, b]);
    });

    test('只有一台聽過的播放：備份不多存東西', () async {
      final cloud = Cloud();
      final a = await Dev.make('A', cloud);
      final b = await Dev.make('B', cloud);
      await a.song('a');
      await b.song('a');
      await a.play('a', seconds: 60);
      await settle([a, b]);
      final dir = await Directory.systemTemp.createTemp('ouo_plain');
      for (final d in [a, b]) {
        final plays = (await buildBackup(d.db, lyricsDir: dir))['listening'] as List;
        expect((plays.single as Map).containsKey('parts'), isFalse, reason: d.name);
      }
    });

    test('這台的狀態不進備份', () async {
      final app = await openDb();
      await app.setSetting('sync2_now', '{}');
      await app.setSetting('sync2_now_kept', '[]');
      final dir = await Directory.systemTemp.createTemp('ouo_state');
      final settings = (await buildBackup(app, lyricsDir: dir))['settings'] as Map;
      expect(settings.keys.where((k) => '$k'.startsWith('sync2_now')), isEmpty);
    });
  });

  group('備份大小', () {
    late Dev a;
    late Directory dir;
    late List<int> picture;
    setUp(() async {
      a = await Dev.make('A', Cloud());
      dir = await Directory.systemTemp.createTemp('ouo_backup');
      picture = List.filled(300 * 1024, 7);
      for (var i = 0; i < 30; i++) {
        final t = await a.song('s$i');
        final art = File('${dir.path}/c$i.jpg')..writeAsBytesSync(picture);
        // As after a download: the official cover, changed by nobody's hand.
        await a.db.updateTrackInfo(
            Track(id: t.id, uri: t.uri, title: t.title, artist: t.artist, album: t.album, durationMs: t.durationMs, art: art.path, source: t.source, addedAt: t.addedAt));
      }
    });

    Future<Map<String, dynamic>> backup() async => jsonDecode(jsonEncode(await buildBackup(a.db, lyricsDir: dir))) as Map<String, dynamic>;

    test('歌曲封面不進備份：30 首不到 0.1 MB', () async {
      final b = await backup();
      expect(b.containsKey('covers'), isFalse);
      expect(utf8.encode(jsonEncode(b)).length, lessThan(100 * 1024));
    });

    test('播放清單自訂封面照存、還原得回來', () async {
      final id = await a.db.createPlaylist('L');
      final cover = File('${dir.path}/list.jpg')..writeAsStringSync('list cover');
      await a.db.db.update('playlists', {'cover': cover.path}, where: 'id = ?', whereArgs: [id]);
      final b = await backup();
      final fresh = await openDb();
      await restoreBackup(fresh, LibraryScanner(fresh), b, coverDir: dir, lyricsDir: dir);
      final restored = (await fresh.db.query('playlists', where: "name = 'L'")).single['cover'] as String;
      expect(File(restored).readAsStringSync(), 'list cover');
    });

    test('還原到同一台：現有的歌曲封面不會不見', () async {
      final before = (await a.track('s3')).art;
      await restoreBackup(a.db, LibraryScanner(a.db), await backup(), coverDir: dir, lyricsDir: dir);
      expect((await a.track('s3')).art, before);
    });

    test('舊備份裡的封面照樣還原', () async {
      final t = await a.track('s3');
      final b = await backup();
      b['covers'] = {t.uri: base64Encode(utf8.encode('old backup cover'))};
      await restoreBackup(a.db, CoverScanner(a.db, dir), b, coverDir: dir, lyricsDir: dir, parts: {RestorePart.songs});
      expect(File((await a.track('s3')).art!).readAsStringSync(), 'old backup cover');
    });
  });

  group('清理舊備份', () {
    test('認得含封面的備份（縮排或不縮排）', () {
      List<int> b(Object v, {bool indent = true}) => utf8.encode(indent ? const JsonEncoder.withIndent(' ').convert(v) : jsonEncode(v));
      expect(AutoBackup.holdsCovers(b({'app': 'OuOPlayer', 'covers': {'/m/a': 'AAAA'}})), isTrue);
      expect(AutoBackup.holdsCovers(b({'app': 'OuOPlayer', 'covers': {'/m/a': 'AAAA'}}, indent: false)), isTrue);
      expect(AutoBackup.holdsCovers(b({'app': 'OuOPlayer', 'covers': {}})), isFalse);
      expect(AutoBackup.holdsCovers(b({'app': 'OuOPlayer', 'playlists': [{'cover': 'BBBB'}]})), isFalse);
      expect(AutoBackup.holdsCovers(b({'app': 'OuOPlayer'})), isFalse);
    });

    late Directory folder;
    late AppDatabase db;
    late ProviderContainer c;

    File put(String name, Map<String, Object?> body) =>
        File('${folder.path}/$name')..writeAsStringSync(const JsonEncoder.withIndent(' ').convert(body));
    List<String> names() => [for (final f in folder.listSync()) f.uri.pathSegments.last]..sort();

    Future<void> run(WidgetTester t, Future<void> Function(Future<void> asked) body, {bool first = false}) async {
      await t.pumpWidget(MaterialApp(navigatorKey: rootNavigatorKey, home: const Scaffold()));
      await t.runAsync(() async {
        folder = await Directory.systemTemp.createTemp('ouo_old_backups');
        db = await openDb();
        c = ProviderContainer(overrides: [dbProvider.overrideWithValue(db)]);
        c.read(autoBackupProvider);
        await wait(100);
        await c.read(autoBackupProvider.notifier).setDir(folder.path);
        for (var i = 1; i <= 3; i++) {
          put('${AutoBackup.prefix}2026-11-0${i}_030000.json', {'app': 'OuOPlayer', 'covers': {'/m/$i': 'AAAA'}});
        }
        put('${AutoBackup.prefix}2026-11-23_030000.json', {'app': 'OuOPlayer'});
        put('OuOPlayer備份_2026-11-01.json', {'app': 'OuOPlayer', 'covers': {'/m/x': 'AAAA'}});
        final ctx = t.element(find.byType(Scaffold));
        final asked = offerBackupCleanup(ctx, db, c.read(autoBackupProvider.notifier), folder.path);
        await body(asked);
        await asked.timeout(const Duration(seconds: 5));
        c.dispose();
      });
      // The top message goes away by itself.
      await t.pump(const Duration(seconds: 10));
      await t.pump(const Duration(seconds: 10));
    }

    Future<bool> shows(WidgetTester t, String text) async {
      for (var i = 0; i < 30; i++) {
        await wait(50);
        await t.pump();
        await t.pump(const Duration(milliseconds: 300));
        if (find.text(text).evaluate().isNotEmpty) return true;
      }
      return false;
    }

    Future<void> tap(WidgetTester t, String text) async {
      await t.tap(find.text(text).last);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
    }

    testWidgets('清理：先存新備份再刪，只刪含封面的自動備份', (t) async {
      await run(t, (asked) async {
        expect(await shows(t, '要清理舊備份嗎？'), isTrue);
        expect(find.textContaining('3 份舊的自動備份'), findsOneWidget);
        await tap(t, '清理');
        expect(await shows(t, '刪除這 3 份舊備份？'), isTrue);
        await tap(t, '刪除');
        await asked;
        final left = names();
        expect(left.where((n) => n.startsWith('${AutoBackup.prefix}2026-11-0')), isEmpty);
        expect(left, contains('${AutoBackup.prefix}2026-11-23_030000.json'));
        expect(left, contains('OuOPlayer備份_2026-11-01.json'));
        expect(left.length, 3, reason: 'the new backup is there');
        expect(await db.allSettings().then((m) => m[backupCleanupKey]), 'cleaned');
        await t.pump(const Duration(milliseconds: 300));
        final message = find.textContaining('已清理 3 份舊備份');
        expect(message, findsOneWidget);
        // At the top, like every message.
        expect(t.getTopLeft(message).dy, lessThan(t.view.physicalSize.height / t.view.devicePixelRatio / 3));
      });
    });

    testWidgets('保留：都不刪，之後不再問', (t) async {
      await run(t, (asked) async {
        expect(await shows(t, '要清理舊備份嗎？'), isTrue);
        await tap(t, '保留');
        await asked;
        expect(names().length, 5);
        expect(await db.allSettings().then((m) => m[backupCleanupKey]), 'kept');
        await offerBackupCleanup(rootNavigatorKey.currentContext!, db, c.read(autoBackupProvider.notifier), folder.path);
        await t.pump();
        expect(find.text('要清理舊備份嗎？'), findsNothing);
      });
    });

    testWidgets('第二個確認按取消：都不刪', (t) async {
      await run(t, (asked) async {
        expect(await shows(t, '要清理舊備份嗎？'), isTrue);
        await tap(t, '清理');
        expect(await shows(t, '刪除這 3 份舊備份？'), isTrue);
        await tap(t, '取消');
        await asked;
        expect(names().length, 5);
      });
    });

    testWidgets('新備份寫不進去：舊的不刪', (t) async {
      await run(t, (asked) async {
        expect(await shows(t, '要清理舊備份嗎？'), isTrue);
        // The folder can't be written any more: a file stands in its place.
        await c.read(autoBackupProvider.notifier).setDir('${folder.path}/${AutoBackup.prefix}2026-11-23_030000.json');
        await tap(t, '清理');
        expect(await shows(t, '刪除這 3 份舊備份？'), isTrue);
        await tap(t, '刪除');
        await asked;
        expect(names().length, 5);
        await t.pump(const Duration(milliseconds: 300));
        final message = find.textContaining('備份失敗，舊備份沒有刪除');
        expect(message, findsOneWidget);
        expect(t.getTopLeft(message).dy, lessThan(t.view.physicalSize.height / t.view.devicePixelRatio / 3));
      });
    });
  });

  group('行動數據', () {
    test('判斷不出來：不傳歌', () async {
      expect(await songsMayTransfer(() async => null), isFalse);
      expect(await songsMayTransfer(() async => true), isFalse);
      expect(await songsMayTransfer(() async => false), isTrue);
    });

    test('網路判斷不靠 MainActivity', () {
      final activity = File('android/app/src/main/kotlin/com/ouo/ouoplayer/MainActivity.kt').readAsStringSync();
      expect(activity, isNot(contains('MethodChannel(messenger, "ouo/network")')));
      final plugin = File('third_party/ouo_network/android/src/main/java/com/ouo/network/OuoNetworkPlugin.java').readAsStringSync();
      expect(plugin, contains('"ouo/network"'));
      expect(File('pubspec.yaml').readAsStringSync(), contains('path: third_party/ouo_network'));
    });
  });
}

