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
import '../services/desktop_tray.dart';
import '../services/network_check.dart';
import '../services/sync/drive_client.dart';
import '../services/sync/google_auth.dart';
import '../services/sync2/engine.dart';
import '../services/sync2/merge.dart' show songKey;
import '../services/sync2/now_playing.dart';
import '../services/tag_editor.dart';
import '../ui/widgets/dialogs.dart';
import 'providers.dart';

/// Playlist sync can sign in here (Windows builds need the OAuth client from the keys folder).
bool get syncAvailable => Platform.isAndroid || (Platform.isWindows && googleDesktopClientId.isNotEmpty);

final googleAuthProvider = Provider<GoogleAuth>((ref) => GoogleAuth(ref.watch(dbProvider)));

final syncEngineProvider = Provider<SyncEngine>((ref) {
  final db = ref.watch(dbProvider);
  final scanner = ref.watch(scannerProvider);
  final lyrics = ref.watch(lyricsServiceProvider);
  Future<String> deviceId() async {
    final s = await db.allSettings();
    final id = s['sync_device_id'];
    if (id != null && id.isNotEmpty) return id;
    final r = Random.secure();
    final made = List.generate(12, (_) => r.nextInt(36).toRadixString(36)).join();
    await db.setSetting('sync_device_id', made);
    return made;
  }

  return SyncEngine(
    db: db,
    drive: DriveClient(ref.watch(googleAuthProvider)),
    deviceId: deviceId,
    deviceName: Platform.isAndroid ? '手機' : '電腦（${Platform.localHostname}）',
    importFile: (path) => scanner.importFile(path, source: TrackSource.download),
    storeArt: scanner.storeArt,
    downloadDir: () => ref.read(settingsProvider).downloadDir,
    lyricsOf: lyrics.entry,
    setLyrics: lyrics.store,
    // Windows: another device's edits go into the file too. Android would ask
    // about each file other apps made, in the middle of a sync: library only.
    writeTags: Platform.isWindows
        ? (t, cover) async {
            if (t.source != TrackSource.local && t.source != TrackSource.download) return;
            await writeTags(t.uri, TagEdit(title: t.title, artist: t.artist, album: t.album, cover: cover, coverMime: 'image/jpeg'));
          }
        : null,
  );
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
  }

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
  /// while syncing: runs again right after. [retry]: the every-minute sync
  /// while songs are missing, which doesn't end a pause (the others do).
  Future<void> run({bool auto = false, bool retry = false}) async {
    if (!syncAvailable || !state.signedIn) return;
    if (state.running) {
      _again = true;
      return;
    }
    if (!retry && _engine.paused) _engine.resume();
    state = state.copyWith(running: true);
    _capGb = (await ref.read(dbProvider).allSettings())['sync_relay_gb'] ?? '5';
    String message;
    var downloads = 0;
    try {
      final r = await _engine.sync(confirmDelete: _confirmDelete, relayCap: relayCap);
      message = r.sent == 0 && r.received == 0 ? '已同步，沒有變更' : '已同步：送出 ${r.sent} 項、收到 ${r.received} 項';
      downloads = r.downloads;
      incomplete = r.incomplete;
      await ref.read(dbProvider).setSetting('sync_last', '${DateTime.now().millisecondsSinceEpoch}');
    } on SignedOut {
      message = 'Google 登入已過期，請重新登入';
      state = state.copyWith(signedIn: false);
    } catch (e) {
      message = '${e is SocketException || '$e'.contains('Socket') || '$e'.contains('connection') ? '網路連線中斷' : '同步失敗：$e'}，稍後會自動再同步';
    }
    _endedAt = DateTime.now();
    state = state.copyWith(running: false, last: DateTime.now(), message: message);
    if (_again) {
      _again = false;
      unawaited(run(auto: true, retry: true));
      return;
    }
    unawaited(_transfers(then: downloads > 0));
  }

  Future<bool> _confirmDelete(String name) async {
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return false;
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: Text('另一台刪除了播放清單「$name」'),
        content: const Text('要在這台也刪除嗎？選「保留」會留下這台的清單，改成不同步的一般播放清單。歌曲檔案都不會被刪除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('刪除')),
          FilledButton(autofocus: true, onPressed: () => Navigator.pop(c, false), child: const Text('保留')),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _transfers({bool then = false}) async {
    if (_engine.pending == 0 || _engine.transfersRunning) return;
    // Phone: songs only over Wi-Fi.
    if (Platform.isAndroid && await onMobileData()) return;
    final done = await _engine.runTransfers(relayCap: relayCap, onProgress: _show);
    // Received songs: tell the other device (its relay copy can go).
    if (done > 0 || then) {
      _endedAt = null;
      unawaited(run(auto: true));
    }
  }

  void pauseTransfers() {
    _engine.pause();
    _show(TransferProgress(done: 0, total: _engine.pending, title: '', upload: true, fraction: 0, paused: true));
  }

  void resumeTransfers() {
    _engine.resume();
    unawaited(_transfers());
  }


  // ---------- 接續播放 ----------

  Future<bool> _nowOn() async => syncAvailable && state.signedIn && (await ref.read(dbProvider).allSettings())['sync_now'] != 'false';

  /// What plays here, to Drive (every minute while playing, on a new song, on
  /// pause, when the app is left).
  Future<void> pushNowPlaying() async {
    if (!await _nowOn()) return;
    final h = ref.read(audioHandlerProvider);
    final list = h.queueTracks;
    final at = h.player.playing ? DateTime.now() : h.lastPlayedAt;
    if (list.isEmpty || at == null || list.every((t) => t.isRemote)) return;
    try {
      await _engine.nowPlaying.put(NowPlaying(
        device: await _engine.deviceId(),
        deviceName: _engine.deviceName,
        at: at.millisecondsSinceEpoch,
        songs: [for (final t in list) SyncEngine.ref(t)],
        index: h.player.currentIndex ?? 0,
        positionMs: h.player.position.inMilliseconds,
        original: h.originalOrder,
        loop: h.player.loopMode.name,
      ));
    } catch (_) {}
  }

  bool _asking = false;

  /// Why the last check didn't ask (read from the database when it doesn't
  /// show up). Only written when it changes.
  String? _resumeNote;
  void _note(String why) {
    if (why == _resumeNote) return;
    _resumeNote = why;
    ref.read(dbProvider).setSetting('sync_resume_debug', '${DateTime.now()} $why').catchError((_) {});
  }

  /// With the app in front (opened, come back to, every minute): the other
  /// device played more recently (within 12 hours) and nothing plays here →
  /// 「要接著播嗎？」, or its queue right away, or nothing ([ResumeMode]);
  /// once for that state.
  Future<void> offerResume() async {
    if (_asking) return _note('already asking');
    if (!await _nowOn()) return _note('off or signed out');
    final h = ref.read(audioHandlerProvider);
    final db = ref.read(dbProvider);
    final mode = ResumeMode.parse((await db.allSettings())['sync_resume_mode']);
    if (mode == ResumeMode.never) return _note('set to never');
    _asking = true;
    try {
      final latest = (await _engine.nowPlaying.others(await _engine.deviceId())).firstOrNull;
      final settings = await db.allSettings();
      final next = resumeStep(
        mode: mode,
        latest: latest,
        now: DateTime.now(),
        lastPlayedHere: h.lastPlayedAt,
        playingHere: h.player.playing,
        asked: settings['sync_resume_asked'],
      );
      if (next.step == ResumeStep.none) return _note(next.why);
      final seen = '${latest!.device}:${latest.at}';
      if (next.step == ResumeStep.load) {
        await db.setSetting('sync_resume_asked', seen);
        _note(next.why);
        await _pickUp(latest);
        return;
      }
      final ctx = rootNavigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return _note('no screen to ask on');
      await db.setSetting('sync_resume_asked', seen);
      _note(next.why);
      if (!ctx.mounted) return;
      final song = latest.current;
      final pos = Duration(milliseconds: latest.positionMs);
      final time = '${pos.inMinutes}:${(pos.inSeconds % 60).toString().padLeft(2, '0')}';
      var remember = false;
      final ok = await showDialog<bool>(
        context: ctx,
        builder: (c) => StatefulBuilder(
          builder: (c, setState) => AlertDialog(
            title: const Text('要接著播嗎？'),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('在${latest.deviceName}上聽到〈${song['t']}〉$time，要從這裡接著播嗎？（不會自動開始播放）'),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('記住我的選擇，不再顯示'),
                value: remember,
                onChanged: (v) => setState(() => remember = v == true),
              ),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('不要')),
              FilledButton(autofocus: true, onPressed: () => Navigator.pop(c, true), child: const Text('接著播')),
            ],
          ),
        ),
      );
      // Closed without answering (tapped outside): nothing is remembered.
      if (ok == null) return;
      if (remember) await db.setSetting('sync_resume_mode', (ok ? ResumeMode.auto : ResumeMode.never).name);
      if (ok) await _pickUp(latest);
    } catch (e) {
      _note('error: $e');
    } finally {
      _asking = false;
    }
  }

  /// The other device's queue here, at its song and second, not playing yet.
  Future<void> _pickUp(NowPlaying latest) async {
    final db = ref.read(dbProvider);
    final h = ref.read(audioHandlerProvider);
    final library = await db.tracks();
    final byKey = <String, Track>{};
    for (final t in library) {
      byKey.putIfAbsent(songKey(t.title, t.artist), () => t);
    }
    for (final r in await db.db.query('track_edits')) {
      final t = library.where((x) => x.id == r['track_id']).firstOrNull;
      if (t != null) byKey.putIfAbsent('${r['root']}', () => t);
    }
    final list = [for (final s in latest.songs) byKey[songKey('${s['t']}', '${s['a']}')]];
    final loop = LoopMode.values.where((m) => m.name == latest.loop).firstOrNull ?? LoopMode.off;
    final done = await h.loadResume(list, latest.index, Duration(milliseconds: latest.positionMs), original: latest.original, loop: loop);
    final ctx = rootNavigatorKey.currentContext;
    if (ctx != null && ctx.mounted) {
      final missing = list.where((t) => t == null).length;
      toast(ctx, !done ? '這台沒有那份佇列裡的歌' : (missing == 0 ? '已接著${latest.deviceName}的進度，按播放繼續聽' : '已接著播，這台沒有的 $missing 首略過'));
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
  Future.delayed(const Duration(seconds: 8), () async {
    await notifier.run(auto: true);
    await notifier.offerResume();
  });
  // In front (not minimised, in the tray, or behind a locked screen).
  var front = true;
  Future<void> look() async {
    await notifier.checkOthers();
    await notifier.offerResume();
  }

  final listener = AppLifecycleListener(
    onHide: () {
      front = false;
      notifier.run(auto: true);
      notifier.pushNowPlaying();
    },
    onShow: () {
      front = true;
      look();
    },
  );
  // 接續播放: what plays here, every minute while playing, on a new song, on pause.
  final h = ref.read(audioHandlerProvider);
  final playing = h.player.playingStream.distinct().skip(1).listen((_) => notifier.pushNowPlaying());
  final song = h.player.currentIndexStream.distinct().skip(1).listen((_) => notifier.pushNowPlaying());
  final nowTimer = Timer.periodic(const Duration(minutes: 1), (_) {
    if (h.player.playing) notifier.pushNowPlaying();
  });
  final every = Timer.periodic(const Duration(minutes: 15), (_) => notifier.run(auto: true));
  // Every minute: songs still missing on a device are tried again until both
  // have them; in front, a look at what the other device did.
  final retry = Timer.periodic(const Duration(minutes: 1), (_) {
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

/// A playlist was just made: when signed in, ask whether to sync it.
Future<void> offerSync(BuildContext context, WidgetRef ref, int playlistId) async {
  if (!syncAvailable || !ref.read(syncProvider).signedIn || !context.mounted) return;
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
  await ref.read(syncEngineProvider).enable(playlistId);
  unawaited(ref.read(syncProvider.notifier).run());
}
