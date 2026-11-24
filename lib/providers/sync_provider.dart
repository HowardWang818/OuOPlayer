import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;

import '../app.dart' show rootNavigatorKey;
import '../config/google_config.dart';
import '../data/models/track.dart';
import '../services/app_screen.dart';
import '../services/desktop_tray.dart';
import '../services/network_check.dart';
import '../services/sync/drive_client.dart';
import '../services/sync/google_auth.dart';
import '../services/sync2/engine.dart';
import '../services/sync2/now_playing.dart';
import '../services/sync2/resume_tracker.dart';
import '../services/sync2/sync_log.dart';
import '../services/tag_backlog.dart';
import '../services/tag_editor.dart';
import '../ui/widgets/dialogs.dart';
import '../ui/widgets/resume_dialog.dart';
import 'providers.dart';
import 'theme_provider.dart';

/// Playlist sync can sign in here (Windows builds need the OAuth client from the keys folder).
bool get syncAvailable => debugSyncAvailable ?? (Platform.isAndroid || (Platform.isWindows && googleDesktopClientId.isNotEmpty));

/// Tests: as if the build had Google's client.
@visibleForTesting
bool? debugSyncAvailable;

final googleAuthProvider = Provider<GoogleAuth>((ref) => GoogleAuth(ref.watch(dbProvider)));

final syncEngineProvider = Provider<SyncEngine>((ref) {
  final db = ref.watch(dbProvider);
  final scanner = ref.watch(scannerProvider);
  final lyrics = ref.watch(lyricsServiceProvider);
  Future<String> readId() async {
    final s = await db.allSettings();
    final id = s['sync_device_id'];
    if (id != null && id.isNotEmpty) return id;
    final r = Random.secure();
    final made = List.generate(12, (_) => r.nextInt(36).toRadixString(36)).join();
    await db.setSetting('sync_device_id', made);
    return made;
  }

  // One for all: asked twice at once on a new install, two were made.
  Future<String>? id;
  Future<String> deviceId() => id ??= readId().catchError((Object e, StackTrace st) {
        id = null;
        Error.throwWithStackTrace(e, st);
      });

  final engine = SyncEngine(
    db: db,
    drive: CachedDrive(DriveClient(ref.watch(googleAuthProvider))),
    deviceId: deviceId,
    deviceName: Platform.isAndroid ? '手機' : '電腦（${Platform.localHostname}）',
    importFile: (path) => scanner.importFile(path, source: TrackSource.download),
    storeArt: scanner.storeArt,
    downloadDir: () => ref.read(settingsProvider).downloadDir,
    lyricsOf: lyrics.entry,
    setLyrics: lyrics.store,
    // Another device's edits go into the file too. Android never asks in the
    // middle of a sync: files it may not write wait in [TagBacklog].
    writeTags: (t, cover) async {
      if (t.source != TrackSource.local && t.source != TrackSource.download) return;
      if (!canWriteTags(t.uri)) return;
      final edit = TagEdit(title: t.title, artist: t.artist, album: t.album, cover: cover, coverMime: 'image/jpeg');
      if (!await writeTagsQuietly(t.uri, edit)) await TagBacklog.add(db, [t.id]);
    },
  );
  // Another device's colour theme: repaint in it.
  engine.onThemeChanged = () {
    ref.read(themeChoiceProvider.notifier).reload();
    ref.read(looksProvider.notifier).reload();
  };
  return engine;
});

/// 接續播放's clock and eyes (tests have their own).
final resumeClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);
final appOnScreenProvider = Provider<Future<bool> Function()>((ref) => appOnScreen);

final resumeTrackerProvider = Provider<ResumeTracker>((ref) {
  final engine = ref.read(syncEngineProvider);
  final tracker = ResumeTracker(ref.read(dbProvider), ref.read(audioHandlerProvider),
      deviceId: engine.deviceId, deviceName: engine.deviceName, clock: ref.read(resumeClockProvider));
  ref.onDispose(tracker.dispose);
  return tracker;
});

/// What the 同步 page shows.
class SyncState {
  const SyncState({this.signedIn = false, this.email, this.last, this.running = false, this.message});
  final bool signedIn;
  final String? email;
  final DateTime? last;
  final bool running;
  final String? message;

  SyncState copyWith({bool? signedIn, String? email, DateTime? last, bool? running, String? message}) => SyncState(
        signedIn: signedIn ?? this.signedIn,
        email: email ?? this.email,
        last: last ?? this.last,
        running: running ?? this.running,
        message: message,
      );
}

class SyncNotifier extends Notifier<SyncState> {
  SyncEngine get _engine => ref.read(syncEngineProvider);
  DateTime? _endedAt;
  bool _again = false;

  /// The last sync found a synced song still missing on a device: syncs
  /// every minute (instead of 15) until both have everything.
  bool incomplete = false;

  @override
  SyncState build() {
    _load();
    return const SyncState();
  }

  Future<void> _load() async {
    final s = await ref.read(dbProvider).allSettings();
    final last = int.tryParse(s['sync_last'] ?? '');
    state = state.copyWith(
      signedIn: s['sync_signed_in'] == 'true' || (s['gdrive_refresh'] ?? '').isNotEmpty,
      email: s['sync_email'],
      last: last == null ? null : DateTime.fromMillisecondsSinceEpoch(last),
    );
    // 暫停 holds until 繼續 or 立即同步, even after the app is closed (1.20.15).
    if (s[_pausedKey] == 'true') _engine.pause();
  }

  static const _pausedKey = 'sync_paused';

  /// Syncing now or just finished: library changes now are the sync's own.
  bool get quiet => state.running || (_endedAt != null && DateTime.now().difference(_endedAt!) < const Duration(seconds: 15));

  Future<void> signIn(BuildContext context) async {
    try {
      if (await ref.read(googleAuthProvider).token(interactive: true) == null) return;
      final email = await DriveClient(ref.read(googleAuthProvider)).email().catchError((_) => null);
      if (email != null) await ref.read(dbProvider).setSetting('sync_email', email);
      state = state.copyWith(signedIn: true, email: email);
      await run();
    } catch (e) {
      if (context.mounted) toast(context, '登入沒有完成：$e');
    }
  }

  Future<void> signOut() async {
    await ref.read(googleAuthProvider).signOut();
    await ref.read(dbProvider).setSetting('sync_email', '');
    state = const SyncState();
  }

  /// Relay limit (bytes), 設定 → 同步.
  int get relayCap => (int.tryParse(_capGb) ?? 5) << 30;
  String _capGb = '5';

  /// One sync, then the songs on their way (phone: only on Wi-Fi). Asked
  /// while syncing: runs again right after. Only a sync the user asked for
  /// (not [auto], not [retry]) ends a pause: before 1.20.15 every automatic
  /// sync did, so 暫停 lasted seconds.
  Future<void> run({bool auto = false, bool retry = false}) async {
    if (!syncAvailable || !state.signedIn) {
      unawaited(_tagBacklog());
      return;
    }
    if (state.running) {
      _again = true;
      return;
    }
    if (!auto && !retry && _engine.paused) await _setPaused(false);
    state = state.copyWith(running: true);
    _capGb = (await ref.read(dbProvider).allSettings())['sync_relay_gb'] ?? '5';
    String message;
    var downloads = 0;
    try {
      final r = await _engine.sync(relayCap: relayCap);
      message = r.sent == 0 && r.received == 0 ? '已同步，沒有變更' : '已同步：送出 ${r.sent} 項、收到 ${r.received} 項';
      downloads = r.downloads;
      incomplete = r.incomplete;
      await ref.read(dbProvider).setSetting('sync_last', '${DateTime.now().millisecondsSinceEpoch}');
    } on SignedOut {
      message = 'Google 登入已過期，請重新登入';
      state = state.copyWith(signedIn: false);
      await SyncLog.add(ref.read(dbProvider), [SyncLogEntry(DateTime.now(), message)]);
    } catch (e) {
      final offline = e is SocketException || '$e'.contains('Socket') || '$e'.contains('connection');
      message = '${offline ? '網路連線中斷' : '同步失敗：$e'}，稍後會自動再同步';
      // 同步紀錄 keeps it (the line on the 同步 page is replaced by the next sync).
      if (!offline) await SyncLog.add(ref.read(dbProvider), [SyncLogEntry(DateTime.now(), '同步失敗：$e')]);
    }
    _endedAt = DateTime.now();
    state = state.copyWith(running: false, last: DateTime.now(), message: message);
    unawaited(pushNowPlaying());
    unawaited(_tagBacklog());
    if (_again) {
      _again = false;
      unawaited(run(auto: true, retry: true));
      return;
    }
    unawaited(_transfers(then: downloads > 0));
  }

  bool _askedTags = false;

  /// Names changed in OuOPlayer that aren't in the files yet: written without
  /// asking where allowed; on Android the rest after one question per run.
  Future<void> _tagBacklog() async {
    final db = ref.read(dbProvider);
    try {
      await TagBacklog.findOld(db);
      await TagBacklog.writeQuietly(db);
      if (!Platform.isAndroid || _askedTags) return;
      final songs = await TagBacklog.songs(db);
      final ctx = rootNavigatorKey.currentContext;
      if (songs.isEmpty || ctx == null || !ctx.mounted) return;
      _askedTags = true;
      final ok = await showDialog<bool>(
        context: ctx,
        builder: (c) => AlertDialog(
          title: Text('把 ${songs.length} 首歌的歌名寫進檔案？'),
          content: const Text('這些歌改過的歌名（自己改的或另一台同步來的）目前只存在 OuOPlayer 裡。寫進檔案後，重新安裝也不會不見。\n\nAndroid 會詢問一次是否允許修改這些檔案，聲音不會改變。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('以後再說')),
            FilledButton(autofocus: true, onPressed: () => Navigator.pop(c, true), child: const Text('寫入')),
          ],
        ),
      );
      if (ok != true) return;
      final n = await TagBacklog.write(db, songs);
      final after = rootNavigatorKey.currentContext;
      if (after != null && after.mounted) toast(after, n > 0 ? '已把 $n 首歌的歌名寫進檔案' : '沒有寫入檔案');
    } catch (_) {}
  }

  Future<void> _transfers({bool then = false}) async {
    if (_engine.pending == 0 || _engine.transfersRunning) return;
    if (_engine.paused) {
      // The paused notification (with 繼續) stays up while songs wait.
      _show(TransferProgress(done: 0, total: _engine.pending, title: '', upload: true, fraction: 0, paused: true));
      return;
    }
    // Phone: songs only over Wi-Fi, and not when the network can't be told.
    if (Platform.isAndroid && !await songsMayTransfer()) return;
    final done = await _engine.runTransfers(relayCap: relayCap, onProgress: _show);
    // Received songs: tell the other device (its relay copy can go).
    if (done > 0 || then) {
      _endedAt = null;
      unawaited(run(auto: true));
    }
  }

  Future<void> _setPaused(bool on) async {
    on ? _engine.pause() : _engine.resume();
    await ref.read(dbProvider).setSetting(_pausedKey, '$on');
  }

  Future<void> pauseTransfers() async {
    await _setPaused(true);
    _show(TransferProgress(done: 0, total: _engine.pending, title: '', upload: true, fraction: 0, paused: true));
  }

  Future<void> resumeTransfers() async {
    await _setPaused(false);
    unawaited(_transfers());
  }


  // ---------- 接續播放 ----------

  Future<bool> _nowOn() async => syncAvailable && state.signedIn && (await ref.read(dbProvider).allSettings())['sync_now'] != 'false';

  ResumeTracker get _tracker => ref.read(resumeTrackerProvider);
  DateTime _clock() => ref.read(resumeClockProvider)();

  Future<void>? _pushing;
  bool _pushAgain = false;

  /// The real progress here, to Drive (every minute while playing, on a new
  /// song, on pause, when the app is left, and on opening if it didn't get
  /// through before the app was closed).
  ///
  /// One upload at a time, each with what is newest when it starts: two at
  /// once could end with the older one on Drive (1.23.0).
  Future<void> pushNowPlaying() {
    _tracker.flush();
    final running = _pushing;
    if (running != null) {
      _pushAgain = true;
      return running;
    }
    return _pushing = _push().whenComplete(() {
      _pushing = null;
      // Asked just as the last one finished.
      if (_pushAgain) {
        _pushAgain = false;
        unawaited(pushNowPlaying());
      }
    });
  }

  Future<void> _push() async {
    do {
      _pushAgain = false;
      final t = _tracker;
      await t.ready;
      if (!await _nowOn()) return;
      if (!t.state.pending) {
        nowFailed = false;
        return;
      }
      final rev = t.state.rev;
      try {
        final send = await t.withParts(t.state.toSend()!);
        await _engine.nowPlaying.put(send);
        nowFailed = false;
        t.markSent(rev);
        await ref.read(dbProvider).setSetting(nowPushedKey, '${DateTime.now().millisecondsSinceEpoch}');
      } catch (_) {
        // No network (power saving cuts it in the background): sent again as
        // soon as one gets through (the minute timer, coming back, a sync,
        // the next start).
        nowFailed = true;
        return;
      }
    } while (_pushAgain);
  }

  /// The last upload didn't get through.
  bool nowFailed = false;

  /// The progress here isn't all on Drive yet (kept over a restart).
  bool get nowPending => nowFailed || _tracker.state.pending;
  static const nowPushedKey = 'sync_now_pushed';

  bool _asking = false;

  /// Why the last check didn't ask (read from the database when it doesn't
  /// show up). Only written when it changes.
  String? _resumeNote;
  void _note(String why) {
    if (why == _resumeNote) return;
    _resumeNote = why;
    ref.read(dbProvider).setSetting('sync_resume_debug', '${DateTime.now()} $why').catchError((_) {});
  }

  Future<ResumePlan> _look({required ResumeMode mode, required bool playing, List<NowPlaying>? fetched}) async {
    final t = _tracker;
    final others = fetched ?? await _engine.nowPlaying.others(await _engine.deviceId());
    t.flush();
    final plan = resumePlan(
      mode: mode,
      others: others,
      me: await _engine.deviceId(),
      state: t.state,
      now: _clock(),
      playingHere: playing,
      lastPlayedHere: ref.read(audioHandlerProvider).lastPlayedAt,
      asked: (await ref.read(dbProvider).allSettings())['sync_resume_asked'],
    );
    // Past 12 hours: dealt with, so the next play here is the one to follow.
    if (plan.expired.isNotEmpty) t.settle(plan.expired);
    // Both played: the other's kept at once, it goes on and replaces its file.
    if (plan.both) await t.keep(plan.offers);
    return plan;
  }

  /// With a screen to ask on and nothing playing (opened, come back to,
  /// paused, every minute): another device really played since (30 seconds,
  /// within 12 hours) → 「要接著播嗎？」, or its queue right away, or nothing
  /// ([ResumeMode]). Both played → 「要從哪裡接著播？」, also with 自動接續.
  Future<void> offerResume() async {
    if (_asking) return _note('already asking');
    if (!await _nowOn()) return _note('off or signed out');
    final h = ref.read(audioHandlerProvider);
    final db = ref.read(dbProvider);
    final mode = ResumeMode.parse((await db.allSettings())['sync_resume_mode']);
    if (mode == ResumeMode.never) return _note('set to never');
    if (_asking) return;
    _asking = true;
    try {
      await _tracker.ready;
      final plan = await _look(mode: mode, playing: h.player.playing);
      if (plan.step == ResumeStep.none) return _note(plan.why);
      if (h.previewing) return _note('previewing');
      // Not asked where nobody sees it (1.23.0): it would count as asked.
      final onScreen = ref.read(appOnScreenProvider);
      if (!await onScreen()) return _note(plan.both ? 'two: not on screen' : 'not on screen');
      if (h.player.playing) return _note(plan.both ? 'two: playing here' : 'playing here');
      if (plan.step == ResumeStep.load) {
        _note(plan.why);
        await _follow(plan.offers.first);
        return;
      }
      final ctx = rootNavigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return _note('no screen to ask on');
      _note(plan.why);
      if (plan.step == ResumeStep.ask) {
        await _askOne(ctx, plan.offers.first);
      } else {
        await _askWhich(ctx, plan.offers);
      }
    } catch (e) {
      _note('error: $e');
    } finally {
      _asking = false;
    }
  }

  Future<void> _askOne(BuildContext ctx, NowPlaying offer) async {
    final h = ref.read(audioHandlerProvider);
    final answer = await showResumeAsk(ctx, offer, playing: h.player.playingStream);
    // Play was pressed: asked again when it's paused.
    if (answer == startedPlaying) return _note('playing here');
    final t = _tracker;
    if (answer is! ({bool yes, bool remember})) {
      // Closed without answering (tapped outside): nothing is decided.
      t.hush([offer]);
      return;
    }
    if (answer.remember) {
      await ref.read(dbProvider).setSetting('sync_resume_mode', (answer.yes ? ResumeMode.auto : ResumeMode.never).name);
    }
    if (answer.yes) {
      await _pickUp(offer, settle: [offer]);
    } else {
      t.settle([offer]);
      await t.keep([offer]);
      unawaited(pushNowPlaying());
    }
  }

  Future<void> _askWhich(BuildContext ctx, List<NowPlaying> offers) async {
    final h = ref.read(audioHandlerProvider);
    final t = _tracker;
    final here = t.here();
    await t.keep(offers);
    if (!ctx.mounted) return;
    final picked = await showResumeChoice(
      ctx,
      [for (final o in offers) ResumeChoice(o.deviceName, o), if (here != null) ResumeChoice(hereLabel, here, here: true)],
      playing: h.player.playingStream,
    );
    if (picked == startedPlaying) return _note('two: playing here');
    if (picked is! ResumeChoice) {
      t.hush(offers);
    } else if (picked.here) {
      t.settle(offers);
      unawaited(pushNowPlaying());
    } else {
      await _pickUp(picked.progress, settle: offers);
    }
  }

  static const hereLabel = '這台';

  /// 自動接續: what is replaced is kept, and one listening says so once.
  Future<void> _follow(NowPlaying o, {bool Function()? cancelled, bool quiet = false}) async {
    final before = _tracker.state.settled[o.device];
    final again = before != null && before.took && before.session == o.sessionKey;
    await _pickUp(o, settle: [o], keepHere: !again, quiet: quiet || again, cancelled: cancelled);
  }

  /// [latest]'s queue here, at its song and second, not playing yet.
  /// [settle]: what this decides about. [byHand]: chosen in 設定, so it may
  /// replace what plays (paused then).
  Future<void> _pickUp(NowPlaying latest,
      {required List<NowPlaying> settle, bool keepHere = true, bool quiet = false, bool byHand = false, bool Function()? cancelled}) async {
    final db = ref.read(dbProvider);
    final h = ref.read(audioHandlerProvider);
    final t = _tracker;
    final list = queueHere(latest, await db.tracks(), await db.db.query('track_edits'));
    final none = !list.any((s) => s != null && s.fileExists);
    if (none) {
      // Not again for this listening.
      t.hush(settle);
    } else {
      if (cancelled?.call() ?? false) return;
      if (!byHand && h.player.playing) return;
      t.flush();
      // During a preview: the progress before it.
      final here = t.here() ?? (h.previewing ? t.state.snap : null);
      if (keepHere && here != null && !sameProgress(here, latest)) await t.keep([await t.withParts(here)]);
      if (cancelled?.call() ?? false) return;
      final loop = LoopMode.values.where((m) => m.name == latest.loop).firstOrNull ?? LoopMode.off;
      final began = latest.began;
      final done = await h.loadResume(list, latest.index, Duration(milliseconds: latest.positionMs),
          original: latest.original,
          loop: loop,
          began: began,
          heardMs: latest.heardMs,
          // A version before 1.23.0 sends only the total: all of it theirs.
          parts: began == null ? null : latest.parts ?? {latest.device: latest.heardMs},
          unlessPlaying: !byHand);
      if (!done) return;
      t.settle(settle, took: latest);
      unawaited(pushNowPlaying());
    }
    if (quiet) return;
    final ctx = rootNavigatorKey.currentContext;
    if (ctx != null && ctx.mounted) {
      final missing = list.where((s) => s == null).length;
      final from = latest.device == await _engine.deviceId() ? '先前' : latest.deviceName;
      if (!ctx.mounted) return;
      toast(ctx, none ? '這台沒有那份佇列裡的歌' : (missing == 0 ? '已接著$from的進度，按播放繼續聽' : '已接著播，這台沒有的 $missing 首略過'));
    }
  }

  /// Play pressed with no screen to ask on (widget, headset, car, tray, media
  /// key). 自動接續 and only the other device played: from there, looked up
  /// by [deadline]. Otherwise, or not found in time: this device's own.
  Future<void> beforePlay(bool Function() cancelled, DateTime deadline) async {
    if (!syncAvailable) return;
    final db = ref.read(dbProvider);
    final s = await db.allSettings();
    if (ResumeMode.parse(s['sync_resume_mode']) != ResumeMode.auto || s['sync_now'] == 'false') return;
    // Read here: just started by the button, [state] may not be loaded yet.
    if (s['sync_signed_in'] != 'true' && (s['gdrive_refresh'] ?? '').isEmpty) return;
    final onScreen = ref.read(appOnScreenProvider);
    if (await onScreen()) return;
    final left = deadline.difference(DateTime.now());
    if (left <= Duration.zero) return;
    try {
      final others = await () async {
        await _tracker.ready;
        return _engine.nowPlaying.others(await _engine.deviceId());
      }()
          .timeout(left);
      if (cancelled()) return;
      final plan = await _look(mode: ResumeMode.auto, playing: false, fetched: others);
      if (plan.step != ResumeStep.load) return _note(plan.both ? 'two: played here in the background' : plan.why);
      _note(plan.why);
      await _follow(plan.offers.first, cancelled: cancelled, quiet: true);
    } catch (e) {
      _note('error: $e');
    }
  }

  /// 設定 → 同步 → 接續播放狀態: the same choice again, with what was kept.
  Future<void> chooseProgress(BuildContext context) async {
    final t = _tracker;
    await t.ready;
    final me = await _engine.deviceId();
    var live = const <NowPlaying>[];
    try {
      live = await _engine.nowPlaying.others(me).timeout(const Duration(seconds: 3));
    } catch (_) {
      // Offline: what was kept.
    }
    t.flush();
    final here = t.here();
    final others = [for (final o in live) if (!o.over) o];
    final choices = <ResumeChoice>[];
    void add(String label, NowPlaying n, {bool isHere = false}) {
      if (choices.any((c) => sameProgress(c.progress, n))) return;
      choices.add(ResumeChoice(label, n, here: isHere));
    }

    if (here != null) add(hereLabel, here, isHere: true);
    for (final o in others) {
      add(o.deviceName, o);
    }
    for (final k in t.kept) {
      add(k.device == me ? '這台（先前）' : k.deviceName, k);
    }
    if (!context.mounted) return;
    if (!choices.any((c) => !c.here)) {
      toast(context, '沒有其他進度');
      return;
    }
    if (_asking) return;
    // No question on top of this one (pausing to pick up would bring one).
    _asking = true;
    try {
      final picked = await showResumeChoice(context, choices);
      if (picked is! ResumeChoice) return;
      if (picked.here) {
        t.settle(others);
        unawaited(pushNowPlaying());
        return;
      }
      await _pickUp(picked.progress, settle: [picked.progress, for (final o in others) if (!identical(o, picked.progress)) o], byHand: true);
    } finally {
      _asking = false;
    }
  }

  /// Another device changed something since the last sync: syncs now.
  Future<void> checkOthers() async {
    if (!syncAvailable || !state.signedIn || state.running) return;
    try {
      if (await _engine.othersChanged()) await run(auto: true, retry: true);
    } catch (_) {}
  }

  static const _channel = MethodChannel('ouo/downloads');

  /// Phone: the quiet progress notification. Windows: the taskbar progress bar.
  void _show(TransferProgress? p) {
    if (Platform.isAndroid) {
      if (ref.read(downloadServiceProvider).tasks.any((t) => t.active)) return;
      if (p == null) {
        // Paused: the paused notification stays (with 繼續). Done: it just goes away.
        if (_engine.paused) return;
        _channel.invokeMethod('stop', <String, Object?>{}).catchError((_) => null);
        return;
      }
      _channel.invokeMethod('update', {
        'title': p.full
            ? '雲端中繼站已滿，等另一台下載'
            : p.paused
                ? '傳歌已暫停'
                : '傳歌 ${p.done + 1} / ${p.total}',
        'text': p.title.isEmpty ? '' : '${p.upload ? '上傳' : '下載'}：${p.title}',
        'progress': (p.fraction * 100).round(),
        'transfer': true,
        'paused': p.paused,
      }).catchError((_) => null);
    } else if (Platform.isWindows) {
      // The tray icon's tooltip (when the tray is on). The taskbar progress
      // bar (window_manager setProgressBar) crashed the app.
      DesktopTray.setStatus(p == null
          ? null
          : p.paused
              ? '傳歌已暫停'
              : '傳歌 ${p.done + 1} / ${p.total}：${p.title}');
    }
  }
}

final syncProvider = NotifierProvider<SyncNotifier, SyncState>(SyncNotifier.new);

/// Whether a playlist is synced (its ⋮ menu).
final playlistSyncedProvider = FutureProvider.family<bool, int>((ref, id) {
  ref.watch(dbRevisionProvider);
  return ref.read(syncEngineProvider).isSynced(id);
});

/// Syncs a few seconds after start-up, when the app is left, every 15
/// minutes, and within 10 s of a change (not the changes sync itself makes).
final syncTriggersProvider = Provider<void>((ref) {
  if (!syncAvailable) return;
  ref.watch(syncEngineProvider); // hooks the library's playlist actions
  final notifier = ref.read(syncProvider.notifier);
  final tracker = ref.read(resumeTrackerProvider);
  tracker.onCounts = notifier.pushNowPlaying;
  final started = Timer(const Duration(seconds: 8), () async {
    // First: what didn't get through before the app was closed.
    await notifier.pushNowPlaying();
    await notifier.run(auto: true);
    await notifier.offerResume();
  });
  // In front (not minimised, in the tray, or behind a locked screen).
  var front = true;
  Future<void> look() async {
    await notifier.checkOthers();
    await notifier.offerResume();
  }

  var seen = visibleIn(WidgetsBinding.instance.lifecycleState);
  DateTime? lookedAt;
  final listener = AppLifecycleListener(
    onHide: () {
      front = false;
      notifier.run(auto: true);
      notifier.pushNowPlaying();
    },
    // Not onShow: opened after a start in the background there was no hiding
    // before. On Windows also a window back from the tray (only focus tells).
    onStateChange: (state) {
      final wasSeen = seen;
      seen = visibleIn(state);
      if (!seen) return;
      front = true;
      final now = DateTime.now();
      final focused = Platform.isWindows &&
          state == AppLifecycleState.resumed &&
          (lookedAt == null || now.difference(lookedAt!) > const Duration(seconds: 15));
      if (wasSeen && !focused) return;
      lookedAt = now;
      if (notifier.nowPending) unawaited(notifier.pushNowPlaying());
      unawaited(notifier.offerResume());
      unawaited(notifier.checkOthers());
    },
  );
  // 接續播放: what plays here, every minute while playing, on a new song, on pause.
  final h = ref.read(audioHandlerProvider);
  Timer? paused;
  final playing = h.player.playingStream.distinct().skip(1).listen((on) {
    notifier.pushNowPlaying();
    // 兩台各自播過: playing is never interrupted, so it's asked on pausing.
    paused?.cancel();
    if (!on) paused = Timer(const Duration(seconds: 1), notifier.offerResume);
  });
  final song = h.player.currentIndexStream.distinct().skip(1).listen((_) => notifier.pushNowPlaying());
  final nowTimer = Timer.periodic(const Duration(minutes: 1), (_) {
    if (h.player.playing) notifier.pushNowPlaying();
  });
  final every = Timer.periodic(const Duration(minutes: 15), (_) => notifier.run(auto: true));
  // Every minute: songs still missing on a device are tried again until both
  // have them; in front, a look at what the other device did. Not on mobile
  // data (the phone then syncs on opening, coming to the front, after a
  // change here, and every 15 minutes).
  final retry = Timer.periodic(const Duration(minutes: 1), (_) async {
    // 接續播放 that didn't get through: tiny, so tried even on mobile data.
    if (notifier.nowPending) unawaited(notifier.pushNowPlaying());
    if (await everyMinuteSkipped()) return;
    if (notifier.incomplete) {
      notifier.run(auto: true, retry: true);
      if (front) notifier.offerResume();
    } else if (front) {
      look();
    }
  });
  Timer? soon;
  final changes = ref.read(dbProvider).changes.listen((_) {
    if (notifier.quiet) return;
    soon?.cancel();
    soon = Timer(const Duration(seconds: 10), () => notifier.run(auto: true));
  });
  ref.onDispose(() {
    started.cancel();
    paused?.cancel();
    tracker.onCounts = null;
    listener.dispose();
    playing.cancel();
    song.cancel();
    nowTimer.cancel();
    every.cancel();
    retry.cancel();
    soon?.cancel();
    changes.cancel();
  });
});

/// 重新傳送: a sync now, so another device sends the greyed songs.
Future<void> resendSongs(BuildContext context, WidgetRef ref, List<Track> songs) async {
  if (context.mounted) toast(context, '重新傳送 ${songs.length} 首');
  await ref.read(syncProvider.notifier).run();
}

/// A playlist was just made: when signed in, ask whether to sync it.
Future<void> offerSync(BuildContext context, WidgetRef ref, int playlistId) => offerSyncIn(context, playlistId);

/// [offerSync] where there is no WidgetRef (download sheets, background
/// downloads with the root navigator's context).
Future<void> offerSyncIn(BuildContext context, int playlistId) async {
  if (!context.mounted) return;
  final c = ProviderScope.containerOf(context, listen: false);
  if (!syncAvailable || !c.read(syncProvider).signedIn) return;
  final ok = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (c) => AlertDialog(
      title: const Text('要同步這個播放清單嗎？'),
      content: const Text('同步後，手機和電腦的這個播放清單會保持一致，另一台缺的歌會自動傳過去。之後也可以在播放清單的 ⋮ 選單更改。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('不要')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('同步')),
      ],
    ),
  );
  if (ok != true) return;
  await c.read(syncEngineProvider).enable(playlistId);
  unawaited(c.read(syncProvider.notifier).run(auto: true));
}
