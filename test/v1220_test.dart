// 1.22.0: 試聽完回到原本的佇列, the sorting changes and the mini player's
// button colours. The player is faked (just_audio's platform side); the
// handler, database and widgets are the app's own.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
// ignore: depend_on_referenced_packages
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:ouoplayer/data/db/database.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/providers/providers.dart';
import 'package:ouoplayer/providers/sync_provider.dart';
import 'package:ouoplayer/services/audio_handler.dart';
import 'package:ouoplayer/services/backup.dart';
import 'package:ouoplayer/services/library_scanner.dart';
import 'package:ouoplayer/services/preview_return.dart';
import 'package:ouoplayer/theme/app_theme.dart';
import 'package:ouoplayer/theme/themes.dart';
import 'package:ouoplayer/ui/pages/collection_page.dart';
import 'package:ouoplayer/ui/widgets/mini_player.dart';

import 'v0120_test.dart' show openDb;

// ---------- a fake player platform ----------

class FakePlatform extends JustAudioPlatform {
  FakePlayer? last;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async => last = FakePlayer(request.id);
  @override
  Future<DisposePlayerResponse> disposePlayer(DisposePlayerRequest request) async => DisposePlayerResponse();
  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(DisposeAllPlayersRequest request) async => DisposeAllPlayersResponse();
}

/// An address with 「throws」 fails to load, one with 「silent」 reports an
/// error and never finishes loading (Windows), one with 「slow」 takes 300 ms.
class FakePlayer extends AudioPlayerPlatform {
  FakePlayer(super.id);

  final _events = StreamController<PlaybackEventMessage>.broadcast();
  var count = 0;
  int? index;
  var position = Duration.zero;
  var state = ProcessingStateMessage.idle;
  var loop = LoopModeMessage.off;
  int? error;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;
  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => const Stream.empty();

  void emit() => _events.add(PlaybackEventMessage(
        processingState: state,
        updateTime: DateTime.now(),
        updatePosition: position,
        bufferedPosition: position,
        duration: const Duration(seconds: 200),
        icyMetadata: null,
        currentIndex: index,
        androidAudioSessionId: null,
        errorCode: error,
        errorMessage: error == null ? null : 'failed',
      ));

  void complete() {
    state = ProcessingStateMessage.completed;
    emit();
  }

  void fail() {
    error = 2000;
    state = ProcessingStateMessage.idle;
    emit();
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    final list = (request.audioSourceMessage as ConcatenatingAudioSourceMessage).children;
    count = list.length;
    index = request.initialIndex ?? 0;
    position = request.initialPosition ?? Duration.zero;
    error = null;
    state = ProcessingStateMessage.loading;
    emit();
    final uri = list.isEmpty ? '' : (list[index!] as UriAudioSourceMessage).uri;
    if (uri.contains('throws')) throw PlatformException(code: '404', message: 'not found');
    if (uri.contains('both')) {
      // Android: the load fails, and the same error comes as an event after it.
      Timer.run(fail);
      throw PlatformException(code: '2000', message: 'source error');
    }
    if (uri.contains('silent')) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      fail();
      return Completer<LoadResponse>().future;
    }
    if (uri.contains('slow')) await Future<void>.delayed(const Duration(milliseconds: 300));
    state = ProcessingStateMessage.ready;
    emit();
    return LoadResponse(duration: const Duration(seconds: 200));
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    position = request.position ?? Duration.zero;
    index = request.index ?? index;
    state = ProcessingStateMessage.ready;
    emit();
    return SeekResponse();
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async => PlayResponse();
  @override
  Future<PauseResponse> pause(PauseRequest request) async => PauseResponse();
  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async => DisposeResponse();
  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async => SetVolumeResponse();
  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async => SetSpeedResponse();
  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async => SetPitchResponse();
  @override
  Future<SetSkipSilenceResponse> setSkipSilence(SetSkipSilenceRequest request) async => SetSkipSilenceResponse();
  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    loop = request.loopMode;
    return SetLoopModeResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(SetShuffleModeRequest request) async => SetShuffleModeResponse();
  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(SetShuffleOrderRequest request) async => SetShuffleOrderResponse();
  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(SetAndroidAudioAttributesRequest request) async =>
      SetAndroidAudioAttributesResponse();
  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse> setAutomaticallyWaitsToMinimizeStalling(
          SetAutomaticallyWaitsToMinimizeStallingRequest request) async =>
      SetAutomaticallyWaitsToMinimizeStallingResponse();
  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse> setCanUseNetworkResourcesForLiveStreamingWhilePaused(
          SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest request) async =>
      SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse();
  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(SetPreferredPeakBitRateRequest request) async =>
      SetPreferredPeakBitRateResponse();
  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(ConcatenatingInsertAllRequest request) async {
    count += request.children.length;
    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(ConcatenatingRemoveRangeRequest request) async {
    count -= request.endIndex - request.startIndex;
    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(ConcatenatingMoveRequest request) async => ConcatenatingMoveResponse();
}

// ---------- helpers ----------

Future<void> until(bool Function() ok, {String what = 'the state'}) async {
  for (var i = 0; i < 300; i++) {
    if (ok()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('timed out waiting for $what');
}

Future<void> breathe([int ms = 80]) => Future<void>.delayed(Duration(milliseconds: ms));

Track clip(String name) =>
    Track.fromUrl('https://preview.test/$name.m4a', title: '$name（試聽）', source: TrackSource.preview, durationMs: 30000);

Track entry(String id, {String source = TrackSource.local}) => Track(id: id, uri: id, title: id, source: source);

List<String> ids(Iterable<Track> list) => [for (final t in list) t.id];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('試聽前的佇列', () {
    late List<Track> list;
    BeforePreview make({int index = 1, bool shuffled = false, Set<int> queued = const {}}) => BeforePreview(
          tracks: list,
          index: index,
          position: const Duration(seconds: 73),
          unshuffled: shuffled ? list.reversed.toList() : [],
          shuffled: shuffled,
          upNext: {for (final i in queued) list[i]},
          play: (began: 5, heard: 9),
        );
    setUp(() => list = [for (final id in 'abcde'.split('')) entry(id)]);

    test('加入佇列: after the current song and the ones queued before', () {
      final b = make(queued: {2});
      b.enqueue([entry('x')]);
      expect(ids(b.tracks), ['a', 'b', 'c', 'x', 'd', 'e']);
      expect(ids(b.waiting), ['c', 'x']);
      expect((b.index, b.position.inSeconds), (1, 73));
    });

    test('加入佇列 with nothing before: the first one is what comes back', () {
      list = [];
      final b = make(index: 0);
      b.enqueue([entry('x'), entry('y')]);
      expect((b.current!.id, b.position), ('x', Duration.zero));
      expect(ids(b.waiting), ['y']);
    });

    test('a song before it removed: same song, same second, same play', () {
      final b = make(index: 2)..remove({'a'});
      expect((b.current!.id, b.index, b.position.inSeconds), ('c', 1, 73));
      expect(b.play, isNotNull);
    });

    test('the current one removed: the next that stays, from its start', () {
      final b = make()..remove({'b', 'c'});
      expect((b.current!.id, b.position), ('d', Duration.zero));
      expect(b.play, isNull);
    });

    test('the last one or all removed', () {
      expect((make(index: 4)..remove({'e'})).current!.id, 'd');
      expect((make()..remove({'a', 'b', 'c', 'd', 'e'})).current, isNull);
    });

    test('a song edited: queue, unshuffled order and queued mark follow', () {
      final b = make(shuffled: true, queued: {2});
      expect(b.replace((t) => t.id == 'c' ? entry('C') : null), isTrue);
      expect(ids(b.tracks), ['a', 'b', 'C', 'd', 'e']);
      expect(ids(b.waiting), ['C']);
      expect(b.original, [4, 3, 2, 1, 0]);
    });
  });

  group('試聽完回到原本的佇列', () {
    const session = MethodChannel('com.ryanheise.audio_session');
    late FakePlatform platform;
    late Directory dir;
    late AppDatabase db;
    late OuoAudioHandler h;
    late List<Track> songs;

    FakePlayer fake() => platform.last!;
    int second() => h.player.position.inSeconds;

    /// The queue plays from [index], then is at 1:13.
    Future<void> listen({int index = 2, bool paused = false}) async {
      await h.playTracks(songs, index: index, source: 'playlist:3');
      await until(() => h.player.playing && h.currentTrack?.id == songs[index].id, what: 'the queue');
      await until(() => h.currentPlay != null, what: 'the log');
      await h.seek(const Duration(seconds: 73));
      await breathe();
      if (paused) await h.pause();
    }

    Future<void> preview([String name = 'p']) async {
      expect(await h.playPreview(clip(name)), isTrue);
      await until(() => h.player.playing && h.currentTrack?.source == TrackSource.preview, what: 'the preview');
      await breathe();
    }

    /// Back on [track] at [at] s, paused, and it stays so.
    Future<void> expectBack({int track = 2, int at = 73, List<String>? queue}) async {
      await until(() => h.currentTrack?.id == songs[track].id && h.queueTracks.isNotEmpty, what: 'the queue coming back');
      await breathe();
      expect(h.player.playing, isFalse);
      expect(second(), at);
      expect(ids(h.queueTracks), queue ?? ids(songs));
      expect([for (final m in h.queue.value) m.id], [for (final t in h.queueTracks) t.uri]);
      expect(h.mediaItem.value?.id, songs[track].uri);
      expect(fake().index, h.player.currentIndex);
    }

    setUp(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(session, (_) async => null);
      platform = FakePlatform();
      JustAudioPlatform.instance = platform;
      dir = await Directory.systemTemp.createTemp('ouo_preview');
      songs = [
        for (final n in 'abcde'.split(''))
          () {
            final f = File('${dir.path}${Platform.pathSeparator}$n.mp3')..writeAsStringSync(n);
            return Track(id: f.path, uri: f.path, title: n);
          }(),
      ];
      db = await openDb();
      await db.upsertTracks(songs);
      h = OuoAudioHandler(db)
        ..fadeMs = 0
        ..unplayedFirst = false;
      await breathe();
    });

    tearDown(() async {
      await h.player.pause();
      await breathe();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(session, null);
    });

    test('30 秒播完：同一份佇列、那首、那一秒，停著', () async {
      await listen();
      await preview();
      expect(h.queueTracks.length, 1);
      fake().complete();
      await expectBack();
      expect(h.queueSource, 'playlist:3');
    });

    test('原本停著：回來一樣停著', () async {
      await listen(paused: true);
      await preview();
      fake().complete();
      await expectBack();
    });

    test('按下一首：馬上回去；再按才是真的下一首', () async {
      await listen();
      await preview();
      await h.skipToNext();
      await expectBack();
      await h.skipToNext();
      await until(() => h.currentTrack?.id == songs[3].id);
    });

    test('連按兩次下一首：不會多跳一首', () async {
      await listen();
      await preview();
      await Future.wait([h.skipToNext(), h.skipToNext()]);
      await expectBack();
    });

    test('暫停、拔耳機：只停試聽', () async {
      await listen();
      await preview();
      await h.pause();
      await breathe();
      expect(h.currentTrack?.source, TrackSource.preview);
      await h.play().timeout(const Duration(seconds: 2));
      await h.pause(fade: false);
      await breathe();
      expect(h.currentTrack?.source, TrackSource.preview);
    });

    test('連續試聽：回到第一次之前', () async {
      await listen();
      await preview('p1');
      await h.seek(const Duration(seconds: 12));
      await preview('p2');
      await preview('p3');
      fake().complete();
      await expectBack();
    });

    test('回去途中又試聽：最後還是回到最一開始', () async {
      await listen();
      await preview('p1');
      final back = h.skipToNext();
      await h.playPreview(clip('p2'));
      await back;
      await until(() => h.currentTrack?.source == TrackSource.preview);
      fake().complete();
      await expectBack();
    });

    test('隨機和重複照舊；試聽不會一直重播', () async {
      await h.playTracks(songs, index: 2, shuffle: true);
      await h.cycleRepeat();
      await breathe();
      await h.seek(const Duration(seconds: 73));
      await breathe();
      final order = ids(h.queueTracks);
      final original = h.originalOrder;
      final at = songs.indexWhere((t) => t.id == h.currentTrack!.id);
      await preview();
      expect(h.player.loopMode, LoopMode.off);
      expect(fake().loop, LoopModeMessage.off);
      fake().complete();
      await expectBack(track: at, queue: order);
      expect(h.shuffled, isTrue);
      expect(h.originalOrder, original);
      expect(h.player.loopMode, LoopMode.all);
    });

    test('試聽時開隨機：套在原本的佇列，目前和之前的不動', () async {
      await listen();
      await preview();
      await h.setShuffleMode(AudioServiceShuffleMode.all);
      await h.skipToNext();
      await until(() => h.currentTrack?.id == songs[2].id);
      await breathe();
      expect(h.shuffled, isTrue);
      expect(ids(h.queueTracks.take(3)), ids(songs.take(3)));
      expect(ids(h.queueTracks)..sort(), ids(songs)..sort());
      expect(h.originalOrder!.length, songs.length);
      expect(h.originalOrder, everyElement(greaterThanOrEqualTo(0)));
    });

    test('加入佇列：放進原本的佇列，試聽不會接著播', () async {
      await listen();
      await h.enqueue([songs[0]]);
      await preview();
      expect(h.queueTracks.length, 1);
      await h.enqueue([songs[1]]);
      expect(h.queueTracks.length, 1);
      fake().complete();
      await expectBack(queue: ids([songs[0], songs[1], songs[2], songs[0], songs[1], songs[3], songs[4]]));
      expect((h.isQueuedAt(3), h.isQueuedAt(4), h.isQueuedAt(5)), (true, true, false));
    });

    test('播別首：不再回去，排著的歌跟過去', () async {
      await listen();
      await h.enqueue([songs[0]]);
      await preview();
      await h.playTracks([songs[4], songs[3]], source: 'album:x');
      await until(() => h.currentTrack?.id == songs[4].id);
      expect(ids(h.queueTracks), ids([songs[4], songs[0], songs[3]]));
      expect(h.queueSource, 'album:x');
      await h.skipToNext();
      await until(() => h.currentTrack?.id == songs[0].id);
    });

    test('接續另一台：不再回去', () async {
      await listen();
      await preview();
      await h.pause();
      expect(await h.loadResume([songs[4], songs[3]], 0, const Duration(seconds: 10)), isTrue);
      await breathe();
      expect((h.currentTrack?.id, second(), h.player.playing), (songs[4].id, 10, false));
      await h.skipToNext();
      await until(() => h.currentTrack?.id == songs[3].id);
    });

    test('試聽讀不到：馬上回去', () async {
      await listen();
      expect(await h.playPreview(clip('throws')), isFalse);
      await expectBack();
    });

    test('試聽讀不到（Windows 只回報錯誤）：不用等', () async {
      await listen();
      expect(await h.playPreview(clip('silent')).timeout(const Duration(seconds: 2)), isFalse);
      await expectBack();
    });

    test('試聽讀不到（Android 回報兩次）：回去一次，照樣說無法試聽', () async {
      await listen();
      expect(await h.playPreview(clip('both')), isFalse);
      await expectBack();
    });

    test('試聽播到一半斷掉：回去', () async {
      await listen();
      await preview();
      fake().fail();
      await expectBack();
    });

    test('還在載入就按下一首：回去，不會冒出試聽', () async {
      await listen();
      final loading = h.playPreview(clip('slow'));
      await until(() => h.queueTracks.length == 1);
      await h.skipToNext();
      expect(await loading, isNull);
      await expectBack();
      await breathe(350);
      expect((h.currentTrack?.id, h.player.playing), (songs[2].id, false));
    });

    test('從佇列移除試聽：馬上回去', () async {
      await listen();
      await preview();
      await h.removeAt(0);
      await expectBack();
    });

    test('試聽時刪了原本在播的歌：回到下一首的開頭', () async {
      await listen();
      await preview();
      await h.removeTracks({songs[2].id});
      expect(h.currentTrack?.source, TrackSource.preview);
      await h.skipToNext();
      await expectBack(track: 3, at: 0, queue: ids([songs[0], songs[1], songs[3], songs[4]]));
    });

    test('試聽時改了歌名：回來是新的', () async {
      await listen();
      await preview();
      h.updateTrackInfo(Track(id: songs[2].id, uri: songs[2].uri, title: 'new'));
      await h.skipToNext();
      await expectBack();
      expect(h.mediaItem.value?.title, 'new');
    });

    test('原本是空的：回到什麼都沒播', () async {
      await preview();
      fake().complete();
      await until(() => h.queueTracks.isEmpty && h.mediaItem.value == null);
      await breathe();
      expect((h.player.playing, h.currentTrack, h.queue.value.length), (false, null, 0));
      await h.enqueue([songs[1]]);
      await until(() => h.currentTrack?.id == songs[1].id);
    });

    test('原本是空的、試聽時加入佇列：回到那首', () async {
      await preview();
      await h.enqueue([songs[1]]);
      fake().complete();
      await expectBack(track: 1, at: 0, queue: [songs[1].id]);
    });

    test('試聽時關掉 App：存的和重開都是原本的佇列和秒數', () async {
      await listen();
      await preview();
      await h.seek(const Duration(seconds: 20));
      await h.saveSession();
      final saved = jsonDecode((await db.allSettings())['last_session']!) as Map;
      expect((saved['index'], (saved['position'] as int) ~/ 1000), (2, 73));
      expect((saved['tracks'] as List).length, songs.length);
      await h.player.pause();
      h = OuoAudioHandler(db)..fadeMs = 0;
      expect(await h.restoreSession(), isTrue);
      await breathe();
      expect((h.currentTrack?.id, second(), h.player.playing), (songs[2].id, 73, false));
    });

    test('滑掉 App：回到原本的佇列再停', () async {
      await listen();
      await preview();
      await h.onTaskRemoved();
      expect(h.currentTrack?.id, songs[2].id);
      final saved = jsonDecode((await db.allSettings())['last_session']!) as Map;
      expect((saved['index'], (saved['position'] as int) ~/ 1000), (2, 73));
    });

    test('同一次播放：回來繼續聽不會多一筆', () async {
      await listen();
      final before = h.currentPlay!;
      await preview();
      expect(h.currentPlay, isNull);
      fake().complete();
      await expectBack();
      // What 接續播放 sends while it waits here.
      expect(h.currentPlay?.began, before.began);
      await h.play().timeout(const Duration(seconds: 2));
      await breathe(150);
      expect(h.currentPlay?.began, before.began);
      expect((await db.db.query('listening_log')).length, 1);
      expect((await db.playCounts())[songs[2].id], 1);
    });

    test('試聽不算最後播放的時間', () async {
      await listen(paused: true);
      await breathe();
      final at = h.lastPlayedAt;
      expect(at, isNotNull);
      await preview();
      await h.saveSession();
      await h.pause();
      await h.play().timeout(const Duration(seconds: 2));
      await breathe();
      fake().complete();
      await expectBack();
      expect(h.lastPlayedAt, at);
    });

    test('回去途中：不把試聽的秒數送給另一台', () async {
      await listen();
      await preview();
      final sent = <(int, int)>[];
      final watch = Timer.periodic(const Duration(milliseconds: 1), (_) {
        final q = h.queueTracks;
        if (q.length > 1) sent.add((h.player.currentIndex ?? -1, second()));
      });
      fake().complete();
      await expectBack();
      watch.cancel();
      expect(sent.toSet(), {(2, 73)});
    });
  });

  group('每個播放清單各自記住排序', () {
    test('14 → 15：欄位加上，全部從自訂順序 ↑ 開始', () async {
      final app = await openDb();
      final raw = app.db;
      await raw.execute('DROP TABLE playlists');
      await raw.execute('CREATE TABLE playlists(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, created_at INTEGER, '
          'cover TEXT, folder_id INTEGER, uid TEXT, synced INTEGER)');
      await raw.insert('playlists', {'name': '舊清單', 'created_at': 1});
      await app.setSetting('sort_playlist', 'title:desc');
      await AppDatabase.migrate(raw, 14, 15);
      final p = (await app.playlists()).single;
      expect((p.name, p.sort), ('舊清單', null));
    });

    test('兩個清單互不干擾', () async {
      final app = await openDb();
      final a = await app.createPlaylist('A'), b = await app.createPlaylist('B');
      await app.setPlaylistSort(a, 'custom:desc');
      var sorts = {for (final p in await app.playlists()) p.id: p.sort};
      expect(sorts, {a: 'custom:desc', b: null});
      await app.setPlaylistSort(b, 'title:asc');
      sorts = {for (final p in await app.playlists()) p.id: p.sort};
      expect(sorts, {a: 'custom:desc', b: 'title:asc'});
    });

    test('備份還原帶著排序；舊備份是自訂順序', () async {
      final app = await openDb();
      final dir = await Directory.systemTemp.createTemp('ouo_sort');
      await app.setPlaylistSort(await app.createPlaylist('A'), 'artist:desc');
      await app.createPlaylist('B');
      final backup = jsonDecode(jsonEncode(await buildBackup(app, lyricsDir: dir))) as Map<String, dynamic>;

      final other = await openDb();
      await restoreBackup(other, LibraryScanner(other), backup, coverDir: dir, lyricsDir: dir);
      expect({for (final p in await other.playlists()) p.name: p.sort}, {'A': 'artist:desc', 'B': null});

      for (final p in backup['playlists'] as List) {
        (p as Map).remove('sort');
      }
      await restoreBackup(other, LibraryScanner(other), backup, coverDir: dir, lyricsDir: dir);
      expect([for (final p in await other.playlists()) p.sort], [null, null]);
    });
  });

  group('播放清單頁', () {
    Future<_ListDb> open(WidgetTester tester, {int id = 1, _ListDb? on}) async {
      tester.view
        ..physicalSize = const Size(420, 1000)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final db = on ?? _ListDb();
      await tester.pumpWidget(ProviderScope(
        key: UniqueKey(),
        overrides: [
          dbProvider.overrideWithValue(db),
          audioHandlerProvider.overrideWithValue(_IdleHandler()),
          currentTrackProvider.overrideWithValue(null),
          playlistSyncedProvider.overrideWith((ref, id) async => false),
        ],
        child: MaterialApp(theme: AppTheme.build(presets.first.light), home: CollectionPage.playlist(id, 'list $id')),
      ));
      await tester.pumpAndSettle();
      return db;
    }

    List<String> shown(WidgetTester tester, _ListDb db, [int id = 1]) {
      final rows = [for (final t in db.lists[id]!) t.title];
      return rows..sort((a, b) => tester.getTopLeft(find.text(a)).dy.compareTo(tester.getTopLeft(find.text(b)).dy));
    }

    Future<void> drag(WidgetTester tester, int from, int to) async {
      final handles = find.byIcon(Icons.menu);
      final start = tester.getCenter(handles.at(from));
      final row = tester.getCenter(handles.at(1)).dy - tester.getCenter(handles.at(0)).dy;
      final g = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 100));
      final total = (to - from) * row + (to > from ? 6 : -6);
      for (var i = 0; i < 20; i++) {
        await g.moveBy(Offset(0, total / 20));
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.pump(const Duration(milliseconds: 300));
      await g.up();
      await tester.pumpAndSettle();
    }

    for (final sort in [null, 'custom:desc']) {
      for (var from = 0; from < 4; from++) {
        for (var to = 0; to < 4; to++) {
          if (from == to) continue;
          testWidgets('拖曳 ${sort == null ? '↑' : '↓'} 第 ${from + 1} 列到第 ${to + 1} 列', (tester) async {
            final db = _ListDb()..sorts[1] = sort;
            await open(tester, on: db);
            final want = sort == null ? ['a', 'gone', 'c', 'd'] : ['d', 'c', 'gone', 'a'];
            expect(shown(tester, db), want);
            want.insert(to, want.removeAt(from));
            await drag(tester, from, to);
            expect(shown(tester, db), want);
            expect([for (final t in db.lists[1]!) t.title], sort == null ? want : want.reversed.toList());
          });
        }
      }
    }

    testWidgets('缺少的歌：雲朵＋≡，≡ 和其他列對齊', (tester) async {
      await open(tester);
      expect(find.byIcon(Icons.menu), findsNWidgets(4));
      final xs = {for (var i = 0; i < 4; i++) tester.getCenter(find.byIcon(Icons.menu).at(i)).dx};
      expect(xs.length, 1);
      final cloud = tester.getCenter(find.byIcon(Icons.cloud_off_outlined));
      expect(cloud.dx, tester.getCenter(find.byIcon(Icons.more_vert).last).dx);
      expect(cloud.dx, lessThan(xs.single));
      expect(tester.takeException(), isNull);
    });

    testWidgets('按雲朵：開缺少歌曲的選單，不是沒反應', (tester) async {
      await open(tester);
      await tester.tapAt(tester.getCenter(find.byIcon(Icons.cloud_off_outlined)));
      await tester.pumpAndSettle();
      expect(find.text('從音樂庫選擇'), findsOneWidget);
    });

    testWidgets('多選時都不顯示', (tester) async {
      await open(tester);
      await tester.longPress(find.text('gone'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.menu), findsNothing);
      expect(find.byIcon(Icons.cloud_off_outlined), findsNothing);
    });

    testWidgets('其他排序：沒有 ≡，雲朵還在', (tester) async {
      await open(tester, on: _ListDb()..sorts[1] = 'title:asc');
      expect(find.byIcon(Icons.menu), findsNothing);
      expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
    });

    testWidgets('一個清單 ↓，另一個仍是 ↑', (tester) async {
      final db = _ListDb()..sorts[1] = 'custom:desc';
      await open(tester, id: 2, on: db);
      expect(shown(tester, db, 2), ['x', 'y', 'z']);
      await open(tester, id: 1, on: db);
      expect(shown(tester, db), ['d', 'c', 'gone', 'a']);
    });

    testWidgets('等排序讀到才顯示，不會先閃一下別的順序', (tester) async {
      final db = _ListDb()
        ..sorts[1] = 'custom:desc'
        ..infoDelay = const Duration(milliseconds: 400);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          dbProvider.overrideWithValue(db),
          audioHandlerProvider.overrideWithValue(_IdleHandler()),
          currentTrackProvider.overrideWithValue(null),
          playlistSyncedProvider.overrideWith((ref, id) async => false),
        ],
        child: MaterialApp(home: CollectionPage.playlist(1, 'list')),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('gone'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('gone'), findsOneWidget);
    });
  });

  group('播放列按鈕顏色', () {
    const track = Track(id: 's', uri: 's', title: 'song', artist: 'artist');

    for (final (name, bar, ink) in [
      ('深色封面', const Color(0xFF6B1F3A), Colors.white),
      ('淺色封面', const Color(0xFFF3D9C4), Colors.black87),
    ]) {
      for (final phone in [true, false]) {
        testWidgets('$name・${phone ? '手機' : 'Windows 窄視窗'}：所有主題、深淺模式都和下一首同色', (tester) async {
          for (final preset in presets) {
            for (final brightness in Brightness.values) {
              for (final liked in [false, true]) {
                for (final playing in [false, true]) {
                  final palette = preset.of(brightness);
                  var theme = AppTheme.build(palette);
                  if (phone) {
                    // The tests run on Windows: the phone's button theme by hand.
                    theme = theme.copyWith(
                      iconButtonTheme: palette.dark
                          ? const IconButtonThemeData()
                          : IconButtonThemeData(style: ButtonStyle(foregroundColor: WidgetStatePropertyAll(palette.icon))),
                    );
                  }
                  await tester.pumpWidget(ProviderScope(
                    key: UniqueKey(),
                    overrides: [
                      audioHandlerProvider.overrideWithValue(_IdleHandler()),
                      currentTrackProvider.overrideWithValue(track),
                      artColorProvider.overrideWith((ref, art) async => bar),
                      positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
                      durationProvider.overrideWith((ref) => Stream.value(const Duration(minutes: 3))),
                      playbackStateProvider.overrideWith((ref) => Stream.value(PlaybackState(playing: playing))),
                      favoriteIdsProvider.overrideWith((ref) async => liked ? {'s'} : <String>{}),
                    ],
                    child: MaterialApp(theme: theme, home: const Scaffold(body: MiniPlayer())),
                  ));
                  await tester.pumpAndSettle();
                  for (final icon in [
                    liked ? Icons.favorite : Icons.favorite_border,
                    playing ? Icons.pause : Icons.play_arrow,
                    Icons.skip_next,
                  ]) {
                    final text = tester.widget<RichText>(find.descendant(of: find.byIcon(icon), matching: find.byType(RichText)));
                    expect(text.text.style?.color, ink, reason: '${preset.id} $brightness $icon');
                  }
                }
              }
            }
          }
        });
      }
    }
  });
}

/// Two playlists in memory; the page reads them through the app's providers.
class _ListDb implements AppDatabase {
  final lists = <int, List<Track>>{
    1: [entry('a'), entry('gone', source: TrackSource.missing), entry('c'), entry('d')],
    2: [entry('x'), entry('y'), entry('z')],
  };
  final sorts = <int, String?>{};
  Duration? infoDelay;
  final _changes = StreamController<void>.broadcast();

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<List<Track>> playlistTracks(int id) async => List.of(lists[id]!);

  @override
  Future<List<Playlist>> playlists({int? folder, bool topLevel = false}) async {
    if (infoDelay != null) await Future<void>.delayed(infoDelay!);
    return [for (final e in lists.entries) Playlist(e.key, 'list ${e.key}', e.value.length, null, sort: sorts[e.key])];
  }

  @override
  Future<void> reorderPlaylist(int id, int oldIndex, int newIndex) async {
    final rows = lists[id]!;
    rows.insert(newIndex.clamp(0, rows.length - 1), rows.removeAt(oldIndex));
    _changes.add(null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _IdleHandler implements OuoAudioHandler {
  @override
  String? queueSource;
  @override
  bool get shuffled => false;
  @override
  Stream<bool> get shuffleStream => Stream.value(false);
  @override
  Future<void> play() async {}
  @override
  Future<void> pause({bool fade = true}) async {}
  @override
  Future<void> skipToNext() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
