import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart' show rootNavigatorKey;
import '../config/google_config.dart';
import '../data/models/track.dart';
import '../services/app_screen.dart';
import '../services/desktop_tray.dart';
import '../services/network_check.dart';
import '../data/db/database.dart';
import '../services/sync/drive_client.dart';
import '../services/sync/google_auth.dart';
import '../services/sync2/engine.dart';
import '../services/list_queues.dart';
import '../services/sync2/queue_sync.dart';
import '../services/sync2/sync_log.dart';
import '../services/tag_backlog.dart';
import '../services/tag_editor.dart';
import '../ui/widgets/dialogs.dart';
import 'providers.dart';
import 'theme_provider.dart';

/// Playlist sync can sign in here (Windows builds need the OAuth client from the keys folder).
bool get syncAvailable => debugSyncAvailable ?? (Platform.isAndroid || (Platform.isWindows && googleDesktopClientId.isNotEmpty));

/// Tests: as if the build had Google's client.
@visibleForTesting
bool? debugSyncAvailable;

final googleAuthProvider = Provider<GoogleAuth>((ref) => GoogleAuth(ref.watch(dbProvider)));

/// This device's id in sync (made the first time).
final deviceIdProvider = Provider<Future<String> Function()>((ref) {
  final db = ref.watch(dbProvider);
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
  return () => id ??= readId().catchError((Object e, StackTrace st) {
        id = null;
        Error.throwWithStackTrace(e, st);
      });
});

final syncEngineProvider = Provider<SyncEngine>((ref) {
  final db = ref.watch(dbProvider);
  final scanner = ref.watch(scannerProvider);
  final lyrics = ref.watch(lyricsServiceProvider);
  final deviceId = ref.watch(deviceIdProvider);

  final engine = SyncEngine(
    db: db,
    drive: CachedDrive(DriveClient(ref.watch(googleAuthProvider))),
    deviceId: deviceId,
    deviceName: defaultDeviceName(),
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
  // 裝置名稱 (1.24.0): chosen in 設定 → 同步; the phone's model by default.
  unawaited(deviceNameOf(db).then((n) => engine.deviceName = n).catchError((_) => engine.deviceName));
  // Another device's colour theme: repaint in it.
  engine.onThemeChanged = () {
    ref.read(themeChoiceProvider.notifier).reload();
    ref.read(looksProvider.notifier).reload();
  };
  return engine;
});

/// 裝置名稱 when none was chosen: 手機 or 電腦 with the computer's name (the
/// phone's model is added by [deviceNameOf]).
String defaultDeviceName() => Platform.isAndroid ? '手機' : '電腦（${Platform.localHostname}）';

const deviceNameKey = 'sync_device_name';

/// This device's name in sync: the one chosen, else 手機（model） / 電腦（name）.
Future<String> deviceNameOf(AppDatabase db) async {
  final chosen = (await db.allSettings())[deviceNameKey]?.trim();
  if (chosen != null && chosen.isNotEmpty) return chosen;
  if (!Platform.isAndroid) return defaultDeviceName();
  final model = await phoneModel();
  return model == null || model.isEmpty ? '手機' : '手機（$model）';
}

/// The list queues' clock and eyes (tests have their own).
final queueClockProvider = Provider<int Function()>((ref) => () => DateTime.now().millisecondsSinceEpoch);
final appOnScreenProvider = Provider<Future<bool> Function()>((ref) => appOnScreen);

/// 1.24.0: each playlist's and the liked songs' own queue.
final listQueuesProvider = Provider<ListQueues>((ref) {
  final queues = ListQueues(ref.read(dbProvider), ref.read(audioHandlerProvider), deviceId: ref.read(deviceIdProvider), clock: ref.read(queueClockProvider));
  ref.onDispose(queues.dispose);
  return queues;
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
    // Lists may have become synced: their queues too.
    unawaited(syncQueues());
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




  // ---------- 佇列同步 (1.24.0, instead of 接續播放) ----------

  ListQueues get _queues => ref.read(listQueuesProvider);
  QueueSync? _queueSyncer;
  QueueSync get _queueSync => _queueSyncer ??= QueueSync(db: ref.read(dbProvider), drive: _engine.drive, deviceId: _engine.deviceId, queues: _queues);

  Future<bool> _queuesOn() async {
    if (!syncAvailable) return false;
    if (state.signedIn) return true;
    // Just started (by a media button): the state may not be read yet.
    final s = await ref.read(dbProvider).allSettings();
    return s['sync_signed_in'] == 'true' || (s['gdrive_refresh'] ?? '').isNotEmpty;
  }

  Future<void>? _queueing;
  bool _queueAgain = false;

  /// The synced lists' queues: this device's up, the others' newer ones
  /// taken. One at a time; asked meanwhile, once more right after.
  Future<void> syncQueues() {
    final running = _queueing;
    if (running != null) {
      _queueAgain = true;
      return running;
    }
    return _queueing = _syncQueues().whenComplete(() {
      _queueing = null;
      if (_queueAgain) {
        _queueAgain = false;
        unawaited(syncQueues());
      }
    });
  }

  Future<void> _syncQueues() async {
    do {
      _queueAgain = false;
      if (!await _queuesOn()) return;
      try {
        await _queueSync.run();
        queueFailed = false;
      } catch (_) {
        // No network: tried again by the minute timer, coming back, a sync.
        queueFailed = true;
        return;
      }
    } while (_queueAgain);
  }

  /// The last queue sync didn't get through.
  bool queueFailed = false;

  /// Play pressed with no screen (widget, headset, car, tray, media key):
  /// the other devices' queues first, by [deadline]; not in time, this
  /// device's own.
  Future<void> beforePlay(bool Function() cancelled, DateTime deadline) async {
    if (!await _queuesOn()) return;
    final onScreen = ref.read(appOnScreenProvider);
    if (await onScreen()) return;
    if (!ListQueues.isList(ref.read(audioHandlerProvider).queueSource)) return;
    final left = deadline.difference(DateTime.now());
    if (left <= Duration.zero || cancelled()) return;
    try {
      await syncQueues().timeout(left);
    } catch (_) {}
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
/// The lists' queues (1.24.0): at once on start-up and coming back, after
/// each song and pause, before a song ends, and when the app is closed.
final syncTriggersProvider = Provider<void>((ref) {
  if (!syncAvailable) return;
  ref.watch(syncEngineProvider); // hooks the library's playlist actions
  final notifier = ref.read(syncProvider.notifier);
  final h = ref.read(audioHandlerProvider);
  final queues = ref.read(listQueuesProvider);
  Timer? queueSoon;
  void queueLater() {
    queueSoon?.cancel();
    queueSoon = Timer(const Duration(seconds: 1), () => unawaited(notifier.syncQueues()));
  }

  queues.onAction = (_) => queueLater();
  h
    ..onNearEnd = (() => unawaited(notifier.syncQueues()))
    ..onLeaving = notifier.syncQueues;
  unawaited(Future<void>.delayed(const Duration(milliseconds: 500), notifier.syncQueues));
  final started = Timer(const Duration(seconds: 8), () => notifier.run(auto: true));
  // In front (not minimised, in the tray, or behind a locked screen).
  var front = true;
  var seen = visibleIn(WidgetsBinding.instance.lifecycleState);
  DateTime? lookedAt;
  final listener = AppLifecycleListener(
    onHide: () {
      front = false;
      notifier.run(auto: true);
      unawaited(notifier.syncQueues());
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
      unawaited(notifier.syncQueues());
      unawaited(notifier.checkOthers());
    },
  );
  // Paused: the other devices' queues looked at too.
  final playing = h.player.playingStream.distinct().skip(1).listen((on) {
    if (!on) queueLater();
  });
  final every = Timer.periodic(const Duration(minutes: 15), (_) => notifier.run(auto: true));
  // Every minute: songs still missing on a device are tried again until both
  // have them; in front, a look at what the other device did. Not on mobile
  // data (the phone then syncs on opening, coming to the front, after a
  // change here, and every 15 minutes).
  final retry = Timer.periodic(const Duration(minutes: 1), (_) async {
    // Queues are tiny: tried even on mobile data.
    if (notifier.queueFailed || front) unawaited(notifier.syncQueues());
    if (await everyMinuteSkipped()) return;
    if (notifier.incomplete) {
      notifier.run(auto: true, retry: true);
    } else if (front) {
      unawaited(notifier.checkOthers());
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
    queueSoon?.cancel();
    queues.onAction = null;
    h
      ..onNearEnd = null
      ..onLeaving = null;
    listener.dispose();
    playing.cancel();
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
