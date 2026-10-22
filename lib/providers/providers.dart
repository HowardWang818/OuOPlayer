import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/db/database.dart';
import '../data/models/track.dart';
import '../services/audio_handler.dart';
import '../services/bluetooth/bluetooth_service.dart';
import '../services/download_service.dart';
import '../services/library_scanner.dart';
import '../services/podcast_service.dart';

// ---------- core singletons (overridden in main) ----------
final dbProvider = Provider<AppDatabase>((ref) => throw UnimplementedError());
final audioHandlerProvider = Provider<OuoAudioHandler>((ref) => throw UnimplementedError());
final scannerProvider = Provider<LibraryScanner>((ref) => LibraryScanner(ref.watch(dbProvider)));
final podcastServiceProvider = Provider<PodcastService>((ref) => PodcastService());
final bluetoothProvider = Provider<BluetoothService>((ref) => BluetoothService());
final downloadServiceProvider = Provider<DownloadService>((ref) {
  final svc = DownloadService(ref.watch(scannerProvider));
  svc.outDir = ref.read(settingsProvider).downloadDir;
  ref.listen(settingsProvider.select((s) => s.downloadDir), (_, dir) => svc.outDir = dir);
  return svc;
});

/// Bumps on every database write so the FutureProviders below refetch.
final dbRevisionProvider = StreamProvider<int>((ref) async* {
  var i = 0;
  yield i;
  await for (final _ in ref.watch(dbProvider).changes) {
    yield ++i;
  }
});

// ---------- settings ----------
class AppSettings {
  final ThemeMode themeMode;
  final List<String> musicDirs;
  final String downloadDir;
  final bool btAutoPlay;
  final String ytFormat;

  const AppSettings({
    required this.themeMode,
    required this.musicDirs,
    required this.downloadDir,
    required this.btAutoPlay,
    required this.ytFormat,
  });

  AppSettings copyWith({ThemeMode? themeMode, List<String>? musicDirs, String? downloadDir, bool? btAutoPlay, String? ytFormat}) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        musicDirs: musicDirs ?? this.musicDirs,
        downloadDir: downloadDir ?? this.downloadDir,
        btAutoPlay: btAutoPlay ?? this.btAutoPlay,
        ytFormat: ytFormat ?? this.ytFormat,
      );

  static Future<AppSettings> load(AppDatabase db) async {
    final m = await db.allSettings();
    final defaults = await _defaultDirs();
    return AppSettings(
      themeMode: ThemeMode.values.firstWhere((t) => t.name == m['theme'], orElse: () => ThemeMode.dark),
      musicDirs: m['music_dirs'] != null ? (jsonDecode(m['music_dirs']!) as List).cast<String>() : defaults.music,
      downloadDir: m['download_dir'] ?? defaults.download,
      btAutoPlay: m['bt_autoplay'] != 'false',
      ytFormat: m['yt_format'] ?? 'mp3',
    );
  }

  static Future<({List<String> music, String download})> _defaultDirs() async {
    if (Platform.isWindows) {
      final home = Platform.environment['USERPROFILE'] ?? '';
      final music = p.join(home, 'Music');
      return (music: [music], download: p.join(music, 'OuOPlayer'));
    }
    if (Platform.isAndroid) {
      const music = '/storage/emulated/0/Music';
      var download = '$music/OuOPlayer';
      try {
        await Directory(download).create(recursive: true);
      } catch (_) {
        final ext = await getExternalStorageDirectory();
        download = p.join(ext?.path ?? (await getApplicationDocumentsDirectory()).path, 'Music');
      }
      return (music: [music, '/storage/emulated/0/Download'], download: download);
    }
    final docs = await getApplicationDocumentsDirectory();
    return (music: [docs.path], download: p.join(docs.path, 'OuOPlayer'));
  }
}

final initialSettingsProvider = Provider<AppSettings>((ref) => throw UnimplementedError());

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(initialSettingsProvider);

  AppDatabase get _db => ref.read(dbProvider);

  void setTheme(ThemeMode m) {
    state = state.copyWith(themeMode: m);
    _db.setSetting('theme', m.name);
  }

  void setMusicDirs(List<String> dirs) {
    state = state.copyWith(musicDirs: dirs);
    _db.setSetting('music_dirs', jsonEncode(dirs));
  }

  void setDownloadDir(String dir) {
    state = state.copyWith(downloadDir: dir);
    _db.setSetting('download_dir', dir);
  }

  void setBtAutoPlay(bool v) {
    state = state.copyWith(btAutoPlay: v);
    _db.setSetting('bt_autoplay', '$v');
  }

  void setYtFormat(String f) {
    state = state.copyWith(ytFormat: f);
    _db.setSetting('yt_format', f);
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

// ---------- library ----------
final tracksProvider = FutureProvider<List<Track>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(dbProvider).tracks();
});
final albumsProvider = FutureProvider<List<Album>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(dbProvider).albums();
});
final recentAlbumsProvider = FutureProvider<List<Album>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(dbProvider).recentAlbums();
});
final artistsProvider = FutureProvider<List<Artist>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(dbProvider).artists();
});
final playlistsProvider = FutureProvider<List<Playlist>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(dbProvider).playlists();
});
final favoritesProvider = FutureProvider<List<Track>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(dbProvider).favorites();
});
final favoriteIdsProvider = FutureProvider<Set<String>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(dbProvider).favoriteIds();
});
final recentlyPlayedProvider = FutureProvider<List<Track>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(dbProvider).recentlyPlayed();
});
final podcastsProvider = FutureProvider<List<Podcast>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(dbProvider).podcasts();
});
final albumTracksProvider = FutureProvider.family<List<Track>, String>((ref, album) {
  ref.watch(dbRevisionProvider);
  return ref.watch(dbProvider).albumTracks(album);
});
final artistTracksProvider = FutureProvider.family<List<Track>, String>((ref, artist) {
  ref.watch(dbRevisionProvider);
  return ref.watch(dbProvider).artistTracks(artist);
});
final playlistTracksProvider = FutureProvider.family<List<Track>, int>((ref, id) {
  ref.watch(dbRevisionProvider);
  return ref.watch(dbProvider).playlistTracks(id);
});
final searchProvider = FutureProvider.family<List<Track>, String>((ref, q) {
  ref.watch(dbRevisionProvider);
  if (q.trim().isEmpty) return Future.value(const []);
  return ref.watch(dbProvider).search(q.trim());
});
final podcastFeedProvider = FutureProvider.family<PodcastFeed, String>((ref, url) => ref.watch(podcastServiceProvider).fetch(url));

final scanProgressProvider = StreamProvider<ScanProgress>((ref) => ref.watch(scannerProvider).progress);

// ---------- player ----------
final mediaItemProvider = StreamProvider<MediaItem?>((ref) => ref.watch(audioHandlerProvider).mediaItem);
final playbackStateProvider = StreamProvider<PlaybackState>((ref) => ref.watch(audioHandlerProvider).playbackState);
final queueProvider = StreamProvider<List<MediaItem>>((ref) => ref.watch(audioHandlerProvider).queue);
final positionProvider = StreamProvider<Duration>((ref) => ref.watch(audioHandlerProvider).player.positionStream);
final durationProvider = StreamProvider<Duration?>((ref) => ref.watch(audioHandlerProvider).player.durationStream);
final volumeProvider = StreamProvider<double>((ref) => ref.watch(audioHandlerProvider).player.volumeStream);
final loopModeProvider = StreamProvider<LoopMode>((ref) => ref.watch(audioHandlerProvider).player.loopModeStream);
final shuffleProvider = StreamProvider<bool>((ref) => ref.watch(audioHandlerProvider).player.shuffleModeEnabledStream);

final currentTrackProvider = Provider<Track?>((ref) {
  final item = ref.watch(mediaItemProvider).value;
  return item == null ? null : Track.fromMediaItem(item);
});

/// Colour sampled from the current cover for the Spotify-like gradient.
final artColorProvider = FutureProvider.family<Color?, String?>((ref, art) async {
  if (art == null) return null;
  try {
    final img = art.startsWith('http') ? NetworkImage(art) as ImageProvider : FileImage(File(art));
    final scheme = await ColorScheme.fromImageProvider(provider: img, brightness: Brightness.dark);
    return scheme.primaryContainer;
  } catch (_) {
    return null;
  }
});

// ---------- downloads ----------
final downloadsProvider = StreamProvider<List<DownloadTask>>((ref) async* {
  final svc = ref.watch(downloadServiceProvider);
  yield List.unmodifiable(svc.tasks);
  yield* svc.changes;
});

// ---------- bluetooth / output ----------
final outputDeviceProvider = StreamProvider<OutputDevice>((ref) async* {
  final bt = ref.watch(bluetoothProvider);
  if (!bt.supported) {
    yield OutputDevice.speaker;
    return;
  }
  try {
    yield await bt.currentOutput();
  } catch (_) {
    yield OutputDevice.speaker;
  }
  yield* bt.outputDevice;
});

// ---------- navigation ----------
class TabNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void set(int i) => state = i;
}

final tabProvider = NotifierProvider<TabNotifier, int>(TabNotifier.new);
