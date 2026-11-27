import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import 'app.dart';
import 'ui/pages/onboarding_page.dart' show firstRunProvider;
import 'data/db/database.dart';
import 'config/demo.dart';
import 'config/demo_seed.dart';
import 'providers/providers.dart';
import 'providers/sync_provider.dart';
import 'providers/theme_provider.dart';
import 'theme/looks.dart';
import 'services/car_browser.dart';
import 'services/desktop_tray.dart';
import 'services/audio_handler.dart';
import 'services/artist_merge.dart';
import 'services/library_scanner.dart';
import 'services/listen_link.dart' show LinkInbox;
import 'services/moved_files.dart';
import 'services/volume_normalizer.dart' show loudnessProvider;
import 'services/window_state.dart';
import 'ui/widgets/song_font.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadSongFont();
  if (Platform.isWindows || Platform.isLinux) {
    JustAudioMediaKit.ensureInitialized(windows: true, linux: true);
    JustAudioMediaKit.title = 'OuOPlayer';
  }

  // Started by an ouoplayer:// link (1.21.0): taken once the app is up.
  for (final a in args) {
    if (a.startsWith('ouoplayer:')) LinkInbox.add(a);
  }

  final db = await AppDatabase.open();
  final settings = await AppSettings.load(db);
  final handler = await AudioService.init(
    // A media button may press play before the providers below exist.
    builder: () => OuoAudioHandler(db)..expectBeforePlay(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.ouo.ouoplayer.audio',
      androidNotificationChannelName: 'OuOPlayer 播放',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      androidNotificationIcon: 'drawable/ic_stat_music',
      androidBrowsableRootExtras: CarBrowser.rootExtras,
    ),
  );
  // The last queue loads in the background: a song that can't be opened
  // must never keep the window from showing.
  unawaited(handler.restoreSession());
  // Windows: system tray (closing the window keeps playing and syncing).
  await DesktopTray.init(handler, db, args).catchError((Object e) => debugPrint('tray: $e'));
  await WindowState.init(db, hidden: DesktopTray.startedHidden).catchError((Object e) => debugPrint('window: $e'));
  await DesktopTray.finishStart(args).catchError((Object e) => debugPrint('window: $e'));

  final saved = await db.allSettings();
  // 1.20.12: an artist under its romaji and original names becomes one.
  unawaited(ArtistMerge.learnOld(db).catchError((Object e) => debugPrint('artist merge: $e')));
  // 1.20.15: songs moved to another folder by hand and added again as new ones.
  await MovedFiles.repairOnce(db).catchError((Object e) {
    debugPrint('moved files: $e');
    return 0;
  });
  // 播放記錄 was removed in 1.20.0: its sign-ins and waiting plays go.
  await db.db.delete('settings', where: "key IN ('lastfm_session', 'lastfm_user', 'listenbrainz_token', 'listenbrainz_user', 'scrobble_queue_lastfm', 'scrobble_queue_listenbrainz')");
  // A new install (no songs yet, never through the guide): 第一次使用 shows.
  final firstRun = !isDemo && !saved.containsKey('onboarded') && (await db.trackIds()).isEmpty;
  final container = ProviderContainer(overrides: [
    firstRunProvider.overrideWithValue(firstRun),
    dbProvider.overrideWithValue(db),
    audioHandlerProvider.overrideWithValue(handler),
    initialSettingsProvider.overrideWithValue(settings),
    initialThemeChoiceProvider.overrideWithValue(ThemeChoice.fromSettings(saved)),
    initialLooksProvider.overrideWithValue(Looks.fromSettings(saved)),
  ]);

  // 1.24.0: each list's own queue; a play without a screen takes the other
  // devices' queues first.
  container.read(listQueuesProvider);
  handler.beforePlay = (cancelled, deadline) => container.read(syncProvider.notifier).beforePlay(cancelled, deadline);

  // Android Auto browsing; podcast episodes come from their feeds.
  handler.carBrowser = CarBrowser(db, episodes: (url) async => (await container.read(podcastServiceProvider).fetch(url)).episodes);

  // 1.20.14: songs are measured for 音量平衡 as soon as they come in; the
  // playing and next song's files are not rewritten while in use.
  if (!isDemo) {
    container.read(loudnessProvider)
      ..busy = ((id) => handler.currentTrack?.id == id || handler.nextTrack?.id == id)
      ..start();
  }

  // First launch on desktop: scan the default Music folder automatically.
  if (Platform.isWindows && (await db.trackIds()).isEmpty) {
    LibraryScanner scanner = container.read(scannerProvider);
    scanner.scan({...settings.musicDirs, settings.downloadDir}.toList());
  }

  // Demo copy (README screenshots) only: playlists and history for its demo songs.
  if (isDemo) await seedDemo(db).catchError((Object e) => debugPrint('demo seed: $e'));

  runApp(UncontrolledProviderScope(container: container, child: const OuoApp()));
}
