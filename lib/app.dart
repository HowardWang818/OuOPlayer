import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/models/track.dart';
import 'providers/providers.dart';
import 'services/app_icon.dart';
import 'services/download_notifier.dart';
import 'services/equalizer.dart';
import 'services/missing_songs.dart';
import 'services/network_check.dart';
import 'services/player_widget.dart';
import 'services/volume_normalizer.dart';
import 'services/ytdlp_auto_update.dart';
import 'theme/app_theme.dart';
import 'ui/shell/app_shell.dart';
import 'providers/auto_backup_provider.dart';
import 'providers/sync_provider.dart';
import 'ui/widgets/dialogs.dart';
import 'ui/widgets/update_dialog.dart';
import 'ui/widgets/missing_files_dialog.dart';
import 'ui/widgets/title_bar.dart';

class OuoApp extends ConsumerWidget {
  const OuoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(settingsProvider.select((s) => s.themeMode));
    ref.watch(bluetoothAutomationProvider);
    ref.watch(shareIntentProvider);
    ref.watch(volumeNormalizationProvider);
    ref.watch(carMusicProvider);
    ref.watch(equalizerProvider);
    ref.watch(playerWidgetProvider);
    ref.watch(lyricsInMetadataProvider);
    ref.watch(playbackSettingsProvider);
    ref.watch(downloadNotificationProvider);
    ref.watch(iconFollowThemeProvider);
    ref.watch(autoBackupProvider);
    ref.watch(syncTriggersProvider);
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: 'OuOPlayer',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: mode,
      builder: Platform.isWindows ? (_, child) => Column(children: [const TitleBar(), Expanded(child: child!)]) : null,
      home: const UpdateWatcher(child: MissingFilesWatcher(child: AppShell())),
    );
  }
}

/// Checks for songs whose file is gone at start-up and whenever the app comes
/// back to the foreground (at most once a minute), if enabled.
class MissingFilesWatcher extends ConsumerStatefulWidget {
  const MissingFilesWatcher({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<MissingFilesWatcher> createState() => _MissingFilesWatcherState();
}

class _MissingFilesWatcherState extends ConsumerState<MissingFilesWatcher> {
  late final AppLifecycleListener _lifecycle;
  DateTime? _last;

  @override
  void initState() {
    super.initState();
    final handler = ref.read(audioHandlerProvider);
    _lifecycle = AppLifecycleListener(
      onResume: _check,
      // Remember where playback is (Windows: closing the window doesn't pause).
      onHide: () => unawaited(handler.saveSession()),
      onExitRequested: () async {
        await handler.saveSession();
        return AppExitResponse.exit;
      },
    );
    _unplayable = ref.read(audioHandlerProvider).unplayable.stream.listen((title) {
      if (mounted) toast(context, '無法播放「$title」，已跳過');
    });
    _filled = MissingSongs.filled.listen((songs) {
      if (!mounted || songs.isEmpty) return;
      final f = songs.first;
      final where = f.playlists.isEmpty ? '' : '「${f.playlists.join('」「')}」裡的';
      toast(context, songs.length == 1 ? '已補上$where缺少的歌曲：${f.track.title}' : '已補上 ${songs.length} 首缺少的歌曲');
    });
    Future.delayed(const Duration(seconds: 3), _check);
    // After start-up settles, so it doesn't slow the first screens.
    Future.delayed(const Duration(seconds: 20), () {
      if (mounted) autoUpdateYtDlp(ref, (msg) => mounted ? toast(context, msg) : null);
    });
  }

  void _check() {
    if (!mounted || !ref.read(settingsProvider).autoCleanMissing) return;
    final now = DateTime.now();
    if (_last != null && now.difference(_last!) < const Duration(minutes: 1)) return;
    _last = now;
    checkMissingFiles(context, ref);
  }

  StreamSubscription<List<FilledSong>>? _filled;
  StreamSubscription<String>? _unplayable;

  @override
  void dispose() {
    _lifecycle.dispose();
    _filled?.cancel();
    _unplayable?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Root navigator, for dialogs started from outside the widget tree
/// (e.g. the download notification's "全部取消").
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Android download notification: progress out, taps in.
final downloadNotificationProvider = Provider<void>((ref) {
  if (!Platform.isAndroid) return;
  final svc = ref.read(downloadServiceProvider);
  final notifier = DownloadNotifier(svc);
  ref.onDispose(notifier.dispose);
  const channel = MethodChannel('ouo/downloads');

  Future<void> handle(String? action) async {
    if (action == null) return;
    if (action == 'sync' || action.startsWith('transfer_')) {
      final sync = ref.read(syncProvider.notifier);
      if (action == 'transfer_pause') sync.pauseTransfers();
      if (action == 'transfer_resume') sync.resumeTransfers();
      return;
    }
    ref.read(tabProvider.notifier).set(3);
    if (action != 'cancel_downloads') return;
    final context = rootNavigatorKey.currentContext;
    final active = svc.tasks.where((t) => t.active).toList();
    if (context == null || active.isEmpty) return;
    if (await confirmDelete(context, title: '取消全部下載？', message: '進行中的 ${active.length} 個下載會停止，已下載完成的歌曲會保留。', action: '全部取消')) {
      for (final t in active) {
        await svc.cancel(t);
      }
    }
  }

  channel.setMethodCallHandler((call) async {
    if (call.method == 'action') await handle(call.arguments as String?);
  });
  channel.invokeMethod<String>('initialAction').then(handle).catchError((_) {});
});

/// App 圖示 → 跟隨主題: when OuOPlayer is left, the home screen icon is
/// switched to match the theme (light theme → light icon). Not right away, so
/// switching it never interrupts the app.
final iconFollowThemeProvider = Provider<void>((ref) {
  if (!AppIcon.supported || !ref.watch(settingsProvider.select((s) => s.iconFollowTheme))) return;
  Future<void> sync() async {
    final mode = ref.read(settingsProvider).themeMode;
    final light = switch (mode) {
      ThemeMode.light => true,
      ThemeMode.dark => false,
      ThemeMode.system => WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.light,
    };
    try {
      if (await AppIcon.isLight() != light) await AppIcon.setLight(light);
    } catch (_) {}
  }

  final listener = AppLifecycleListener(onHide: sync);
  ref.onDispose(listener.dispose);
});

/// Whether Android Auto is showing the phone (CarConnectionPlugin.kt).
final carConnectedProvider = StreamProvider<bool>((ref) {
  if (!Platform.isAndroid) return Stream.value(false);
  return const EventChannel('ouo/car').receiveBroadcastStream().map((v) => v == true);
});

/// 連上車子時切回音樂: Android Auto connecting while the app runs.
final carMusicProvider = Provider<void>((ref) {
  ref.listen(carConnectedProvider, (prev, next) {
    if (next.value == true && prev?.value != true) ref.read(audioHandlerProvider).carConnected();
  });
});

/// 歌詞 → 在 Android Auto / 通知列和鎖定畫面顯示歌詞: follows the synced lyrics
/// of the current song and hands the line being sung to the player (see
/// showLyricLine). The car and the notification share one media session, so
/// which switch counts depends on whether the car is connected.
final lyricsInMetadataProvider = Provider<void>((ref) {
  final handler = ref.read(audioHandlerProvider);
  if (!Platform.isAndroid) return;
  final car = ref.watch(carConnectedProvider).value ?? false;
  final on = ref.watch(settingsProvider.select((s) => car ? s.lyricsInCar : s.lyricsInMetadata));
  if (!on) {
    handler.showLyricLine(null);
    return;
  }
  final track = ref.watch(currentTrackProvider);
  if (track == null || track.source == TrackSource.podcast) return;
  final lyrics = ref.watch(lyricsProvider(LyricsKey(track))).value;
  if (lyrics == null || !lyrics.synced) {
    handler.showLyricLine(null);
    return;
  }
  final i = ref.watch(positionProvider.select((p) => lyrics.indexAt(p.value ?? Duration.zero)));
  handler.showLyricLine(i < 0 ? null : lyrics.lines[i].text);
});

/// Pushes the 播放 settings (podcast speed, skip silence, queue end, seek step) into the player.
final playbackSettingsProvider = Provider<void>((ref) {
  final s = ref.watch(settingsProvider);
  ref.read(audioHandlerProvider).updatePlaybackSettings(
        podcastSpeed: s.podcastSpeed,
        podcastSkipSilence: s.podcastSkipSilence,
        continueAfterQueue: s.continueAfterQueue,
        seekSeconds: s.seekSeconds,
        fadeMs: s.fadeMs,
        recordPlays: s.recordPlays,
        unplayedFirst: s.unplayedFirst,
      );
});

/// Android "share to OuOPlayer": queue the first URL in the shared text.
final shareIntentProvider = Provider<void>((ref) {
  if (!Platform.isAndroid) return;
  // Needed for the playback and download notifications on Android 13+.
  Permission.notification.request();
  const channel = MethodChannel('ouo/share');
  Future<void> handle(String? text) async {
    final url = RegExp(r'https?://\S+').firstMatch(text ?? '')?.group(0);
    if (url == null) return;
    if (!await okToDownload(rootNavigatorKey.currentContext, warn: ref.read(settingsProvider).wifiWarning)) return;
    ref.read(downloadServiceProvider).add(url, format: ref.read(settingsProvider).ytFormat);
    ref.read(tabProvider.notifier).set(3);
  }

  channel.setMethodCallHandler((call) async {
    if (call.method == 'shared') handle(call.arguments as String?);
  });
  channel.invokeMethod<String>('initialText').then(handle).catchError((_) {});
});

/// Bluetooth audio connected → resume (if enabled). Disconnects are handled by
/// the audio session's "becoming noisy" event inside the audio handler.
final bluetoothAutomationProvider = Provider<void>((ref) {
  final bt = ref.watch(bluetoothProvider);
  if (!bt.supported) return;
  final sub = bt.audioConnected.listen((_) async {
    if (!ref.read(settingsProvider).btAutoPlay) return;
    // Give Android a moment to route audio to the headset.
    await Future.delayed(const Duration(milliseconds: 1500));
    await ref.read(audioHandlerProvider).play();
  });
  ref.onDispose(sub.cancel);
});
