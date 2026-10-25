import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import 'app.dart';
import 'data/db/database.dart';
import 'config/demo.dart';
import 'config/demo_seed.dart';
import 'providers/providers.dart';
import 'services/car_browser.dart';
import 'services/audio_handler.dart';
import 'services/library_scanner.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows || Platform.isLinux) {
    JustAudioMediaKit.ensureInitialized(windows: true, linux: true);
    JustAudioMediaKit.title = 'OuOPlayer';
  }

  final db = await AppDatabase.open();
  final settings = await AppSettings.load(db);
  final handler = await AudioService.init(
    builder: () => OuoAudioHandler(db),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.ouo.ouoplayer.audio',
      androidNotificationChannelName: 'OuOPlayer 播放',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      androidNotificationIcon: 'drawable/ic_stat_music',
      androidBrowsableRootExtras: CarBrowser.rootExtras,
    ),
  );
  await handler.restoreSession();

  final container = ProviderContainer(overrides: [
    dbProvider.overrideWithValue(db),
    audioHandlerProvider.overrideWithValue(handler),
    initialSettingsProvider.overrideWithValue(settings),
  ]);

  // Android Auto browsing; podcast episodes come from their feeds.
  handler.carBrowser = CarBrowser(db, episodes: (url) async => (await container.read(podcastServiceProvider).fetch(url)).episodes);

  // First launch on desktop: scan the default Music folder automatically.
  if (Platform.isWindows && (await db.trackIds()).isEmpty) {
    LibraryScanner scanner = container.read(scannerProvider);
    scanner.scan({...settings.musicDirs, settings.downloadDir}.toList());
  }

  // Demo copy (README screenshots) only: playlists and history for its demo songs.
  if (isDemo) await seedDemo(db).catchError((Object e) => debugPrint('demo seed: $e'));

  runApp(UncontrolledProviderScope(container: container, child: const OuoApp()));
}
