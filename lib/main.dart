import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import 'app.dart';
import 'data/db/database.dart';
import 'providers/providers.dart';
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
    ),
  );
  await handler.restoreSession();

  final container = ProviderContainer(overrides: [
    dbProvider.overrideWithValue(db),
    audioHandlerProvider.overrideWithValue(handler),
    initialSettingsProvider.overrideWithValue(settings),
  ]);

  // First launch on desktop: scan the default Music folder automatically.
  if (Platform.isWindows && (await db.trackIds()).isEmpty) {
    LibraryScanner scanner = container.read(scannerProvider);
    scanner.scan({...settings.musicDirs, settings.downloadDir}.toList());
  }

  runApp(UncontrolledProviderScope(container: container, child: const OuoApp()));
}
