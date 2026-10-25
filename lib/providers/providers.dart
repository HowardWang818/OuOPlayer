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
import '../config/demo.dart';
import '../services/artist_images.dart';
import '../services/artists.dart';
import '../services/audio_handler.dart';
import '../services/bluetooth/bluetooth_service.dart';
import '../services/download_service.dart';
import '../services/library_scanner.dart';
import '../services/lyrics/lrc.dart';
import '../services/lyrics/lyrics_service.dart';
import '../services/online/itunes.dart';
import '../services/online/youtube_link.dart';
import '../services/podcast_service.dart';

// ---------- core singletons (overridden in main) ----------
final dbProvider = Provider<AppDatabase>((ref) => throw UnimplementedError());
final audioHandlerProvider = Provider<OuoAudioHandler>((ref) => throw UnimplementedError());
final scannerProvider = Provider<LibraryScanner>((ref) => LibraryScanner(ref.watch(dbProvider)));
final podcastServiceProvider = Provider<PodcastService>((ref) => PodcastService());
final iTunesSearchProvider = Provider<ITunesSearch>((ref) => ITunesSearch());
final youTubeLinkFinderProvider = Provider<YouTubeLinkFinder>((ref) => YouTubeLinkFinder());
final Provider<LyricsService> lyricsServiceProvider = Provider<LyricsService>((ref) {
  final svc = LyricsService(ref.watch(scannerProvider));
  svc.onFetched = (_) => ref.invalidate(lyricsProvider);
  return svc;
});

/// Identifies a song for [lyricsProvider]: the current track is rebuilt on
/// every media update (e.g. when its length arrives), so compare by content.
class LyricsKey {
  LyricsKey(this.track);
  final Track track;

  @override
  bool operator ==(Object other) =>
      other is LyricsKey &&
      other.track.uri == track.uri &&
      other.track.title == track.title &&
      other.track.artist == track.artist &&
      other.track.album == track.album;

  @override
  int get hashCode => Object.hash(track.uri, track.title, track.artist, track.album);
}

/// Lyrics for a song (null if none were found).
final lyricsProvider = FutureProvider.family<Lyrics?, LyricsKey>((ref, k) {
  final online = ref.watch(settingsProvider.select((s) => s.lyricsOnline));
  return ref.read(lyricsServiceProvider).find(k.track, online: online);
}, retry: (_, __) => null);

/// Whether the now-playing page shows lyrics instead of (or beside) the cover.
class ShowLyricsNotifier extends Notifier<bool> {
  @override
  bool build() => false;
  void toggle() => state = !state;
}

final showLyricsProvider = NotifierProvider<ShowLyricsNotifier, bool>(ShowLyricsNotifier.new);
final onlineSearchProvider = FutureProvider.family<List<ITunesSong>, String>(
  (ref, q) {
    if (q.trim().isEmpty) return Future.value(const []);
    return ref.watch(iTunesSearchProvider).search(q.trim());
  },
  // Show network errors right away instead of retrying in the background.
  retry: (_, __) => null,
);
final podcastSearchProvider = FutureProvider.family<List<ITunesPodcast>, String>(
  (ref, q) {
    if (q.trim().isEmpty) return Future.value(const []);
    return ref.watch(iTunesSearchProvider).searchPodcasts(q.trim());
  },
  retry: (_, __) => null,
);
final bluetoothProvider = Provider<BluetoothService>((ref) => BluetoothService());
final downloadServiceProvider = Provider<DownloadService>((ref) {
  final svc = DownloadService(ref.watch(scannerProvider), ref.watch(dbProvider));
  svc.outDir = ref.read(settingsProvider).downloadDir;
  // 下載歌曲時自動找歌詞.
  svc.onImported = (t) {
    if (ref.read(settingsProvider).lyricsOnDownload) ref.read(lyricsServiceProvider).fetchLater(t);
  };
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
/// Volume-normalization strength (like Spotify's 安靜 / 一般 / 大聲).
enum NormalizeLevel {
  quiet('安靜'),
  normal('一般'),
  loud('大聲');

  const NormalizeLevel(this.label);
  final String label;
}

const podcastSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
const seekSecondOptions = [10, 15, 30];

class AppSettings {
  final ThemeMode themeMode;
  final List<String> musicDirs;
  final String downloadDir;
  final bool btAutoPlay;
  final String ytFormat;
  final bool normalizeVolume;
  final NormalizeLevel normalizeLevel;
  final bool autoScanNewFolders;
  final double podcastSpeed;
  final bool podcastSkipSilence;
  final bool continueAfterQueue;
  final int seekSeconds;
  final String youtubeApiKey;

  /// Manual 加入播放清單 may add a song that is already in the playlist.
  final bool allowPlaylistDuplicates;

  /// Look for songs whose file is gone (asks before removing them).
  final bool autoCleanMissing;

  /// Look lyrics up on LRCLIB when the file and .lrc have none.
  final bool lyricsOnline;

  /// 刪除檔案 deletes for good instead of moving to the trash.
  final bool deletePermanently;

  /// Smart playlists (SmartList names) not shown in the library.
  final Set<String> hiddenSmartLists;

  /// 等化器 on.
  final bool eqEnabled;

  /// EqPreset name.
  final String eqPreset;

  /// The 自訂 band gains (dB).
  final List<double> eqCustom;

  /// Fade in on play / out on pause (0 = off).
  final int fadeMs;

  /// Lyrics text size, 1.0 = normal.
  final double lyricsScale;

  /// Keep the screen on while lyrics are shown.
  final bool lyricsKeepAwake;

  /// Ask before downloading without Wi-Fi.
  final bool wifiWarning;

  /// Look artist photos up on Deezer.
  final bool artistImagesOnline;

  /// Check the update server once a day when the app opens.
  final bool autoUpdateCheck;

  /// Show the current synced lyric line as the artist in the notification and on the lock screen.
  final bool lyricsInMetadata;

  /// The same in Android Auto, apart from the phone's notification.
  final bool lyricsInCar;

  /// Look lyrics up on LRCLIB right after a song is downloaded.
  final bool lyricsOnDownload;

  /// The app icon follows the theme (dark / light), switched when the app is left.
  final bool iconFollowTheme;

  /// 記錄播放紀錄 (recently played, play counts, listening stats).
  final bool recordPlays;

  /// Update yt-dlp by itself once a week.
  final bool ytAutoUpdate;
  final DateTime? ytLastUpdate;

  /// Sort choices saved per list (「sort_」 + scope settings), see [sortProvider].
  final Map<String, String> sorts;

  const AppSettings({
    required this.themeMode,
    required this.musicDirs,
    required this.downloadDir,
    required this.btAutoPlay,
    required this.ytFormat,
    required this.normalizeVolume,
    required this.normalizeLevel,
    required this.autoScanNewFolders,
    required this.podcastSpeed,
    required this.podcastSkipSilence,
    required this.continueAfterQueue,
    required this.seekSeconds,
    required this.youtubeApiKey,
    this.allowPlaylistDuplicates = false,
    this.autoCleanMissing = true,
    this.lyricsOnline = true,
    this.deletePermanently = false,
    this.hiddenSmartLists = const {},
    this.eqEnabled = false,
    this.eqPreset = 'flat',
    this.eqCustom = const [],
    this.fadeMs = 500,
    this.lyricsScale = 1.0,
    this.lyricsKeepAwake = false,
    this.wifiWarning = true,
    this.recordPlays = true,
    this.lyricsInMetadata = true,
    this.lyricsInCar = true,
    this.lyricsOnDownload = true,
    this.iconFollowTheme = false,
    this.artistImagesOnline = true,
    this.autoUpdateCheck = true,
    this.ytAutoUpdate = true,
    this.ytLastUpdate,
    this.sorts = const {},
  });

  AppSettings copyWith({
    ThemeMode? themeMode,
    List<String>? musicDirs,
    String? downloadDir,
    bool? btAutoPlay,
    String? ytFormat,
    bool? normalizeVolume,
    NormalizeLevel? normalizeLevel,
    bool? autoScanNewFolders,
    double? podcastSpeed,
    bool? podcastSkipSilence,
    bool? continueAfterQueue,
    int? seekSeconds,
    String? youtubeApiKey,
    bool? allowPlaylistDuplicates,
    bool? autoCleanMissing,
    bool? lyricsOnline,
    bool? deletePermanently,
    Set<String>? hiddenSmartLists,
    bool? eqEnabled,
    String? eqPreset,
    List<double>? eqCustom,
    int? fadeMs,
    double? lyricsScale,
    bool? lyricsKeepAwake,
    bool? wifiWarning,
    bool? recordPlays,
    bool? lyricsInMetadata,
    bool? lyricsInCar,
    bool? lyricsOnDownload,
    bool? iconFollowTheme,
    bool? artistImagesOnline,
    bool? autoUpdateCheck,
    bool? ytAutoUpdate,
    DateTime? ytLastUpdate,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        musicDirs: musicDirs ?? this.musicDirs,
        downloadDir: downloadDir ?? this.downloadDir,
        btAutoPlay: btAutoPlay ?? this.btAutoPlay,
        ytFormat: ytFormat ?? this.ytFormat,
        normalizeVolume: normalizeVolume ?? this.normalizeVolume,
        normalizeLevel: normalizeLevel ?? this.normalizeLevel,
        autoScanNewFolders: autoScanNewFolders ?? this.autoScanNewFolders,
        podcastSpeed: podcastSpeed ?? this.podcastSpeed,
        podcastSkipSilence: podcastSkipSilence ?? this.podcastSkipSilence,
        continueAfterQueue: continueAfterQueue ?? this.continueAfterQueue,
        seekSeconds: seekSeconds ?? this.seekSeconds,
        youtubeApiKey: youtubeApiKey ?? this.youtubeApiKey,
        allowPlaylistDuplicates: allowPlaylistDuplicates ?? this.allowPlaylistDuplicates,
        autoCleanMissing: autoCleanMissing ?? this.autoCleanMissing,
        lyricsOnline: lyricsOnline ?? this.lyricsOnline,
        deletePermanently: deletePermanently ?? this.deletePermanently,
        hiddenSmartLists: hiddenSmartLists ?? this.hiddenSmartLists,
        eqEnabled: eqEnabled ?? this.eqEnabled,
        eqPreset: eqPreset ?? this.eqPreset,
        eqCustom: eqCustom ?? this.eqCustom,
        fadeMs: fadeMs ?? this.fadeMs,
        lyricsScale: lyricsScale ?? this.lyricsScale,
        lyricsKeepAwake: lyricsKeepAwake ?? this.lyricsKeepAwake,
        wifiWarning: wifiWarning ?? this.wifiWarning,
        recordPlays: recordPlays ?? this.recordPlays,
        lyricsInMetadata: lyricsInMetadata ?? this.lyricsInMetadata,
        lyricsInCar: lyricsInCar ?? this.lyricsInCar,
        lyricsOnDownload: lyricsOnDownload ?? this.lyricsOnDownload,
        iconFollowTheme: iconFollowTheme ?? this.iconFollowTheme,
        artistImagesOnline: artistImagesOnline ?? this.artistImagesOnline,
        autoUpdateCheck: autoUpdateCheck ?? this.autoUpdateCheck,
        ytAutoUpdate: ytAutoUpdate ?? this.ytAutoUpdate,
        ytLastUpdate: ytLastUpdate ?? this.ytLastUpdate,
        sorts: sorts,
      );

  static Future<AppSettings> load(AppDatabase db) async {
    final m = await db.allSettings();
    final defaults = await _defaultDirs();
    try {
      ArtistRenames.set((jsonDecode(m['artist_renames'] ?? '{}') as Map).cast<String, String>());
    } catch (_) {
      ArtistRenames.set(const {});
    }
    return AppSettings(
      themeMode: ThemeMode.values.firstWhere((t) => t.name == m['theme'], orElse: () => ThemeMode.dark),
      musicDirs: m['music_dirs'] != null ? (jsonDecode(m['music_dirs']!) as List).cast<String>() : defaults.music,
      downloadDir: m['download_dir'] ?? defaults.download,
      btAutoPlay: m['bt_autoplay'] != 'false',
      // M4A by default: usually no re-encoding, so much faster than MP3.
      ytFormat: m['yt_format'] ?? 'm4a',
      normalizeVolume: m['normalize_volume'] != 'false',
      normalizeLevel: NormalizeLevel.values.firstWhere((l) => l.name == m['normalize_level'], orElse: () => NormalizeLevel.normal),
      autoScanNewFolders: m['auto_scan_new_folders'] != 'false',
      podcastSpeed: double.tryParse(m['podcast_speed'] ?? '') ?? 1.0,
      podcastSkipSilence: m['podcast_skip_silence'] == 'true',
      continueAfterQueue: m['continue_after_queue'] != 'false',
      seekSeconds: int.tryParse(m['seek_seconds'] ?? '') ?? 15,
      youtubeApiKey: m['youtube_api_key'] ?? '',
      allowPlaylistDuplicates: m['allow_playlist_duplicates'] == 'true',
      autoCleanMissing: m['auto_clean_missing'] != 'false',
      lyricsOnline: !isDemo && m['lyrics_online'] != 'false',
      deletePermanently: m['delete_permanently'] == 'true',
      hiddenSmartLists: (m['hidden_smart_lists'] ?? '').split(',').where((s) => s.isNotEmpty).toSet(),
      eqEnabled: m['eq_enabled'] == 'true',
      eqPreset: m['eq_preset'] ?? 'flat',
      eqCustom: (m['eq_custom'] ?? '').split(',').map(double.tryParse).whereType<double>().toList(),
      fadeMs: int.tryParse(m['fade_ms'] ?? '') ?? 500,
      lyricsScale: double.tryParse(m['lyrics_scale'] ?? '') ?? 1.0,
      lyricsKeepAwake: m['lyrics_keep_awake'] == 'true',
      wifiWarning: m['wifi_warning'] != 'false',
      recordPlays: m['record_plays'] != 'false',
      // On unless turned off (before v0.18.4 one switch, off by default, did both).
      lyricsInMetadata: m['lyrics_in_metadata'] != 'false',
      lyricsInCar: (m['lyrics_in_car'] ?? m['lyrics_in_metadata']) != 'false',
      lyricsOnDownload: m['lyrics_on_download'] != 'false',
      iconFollowTheme: m['icon_follow_theme'] == 'true',
      artistImagesOnline: !isDemo && m['artist_images_online'] != 'false',
      autoUpdateCheck: !isDemo && m['auto_update_check'] != 'false',
      ytAutoUpdate: m['yt_auto_update'] != 'false',
      ytLastUpdate: DateTime.tryParse(m['yt_last_update'] ?? ''),
      sorts: {for (final e in m.entries) if (e.key.startsWith('sort_')) e.key.substring(5): e.value},
    );
  }

  static Future<({List<String> music, String download})> _defaultDirs() async {
    if (Platform.isWindows) {
      final home = Platform.environment['USERPROFILE'] ?? '';
      final music = p.join(home, 'Music');
      return (music: [music], download: p.join(music, 'OuOPlayer'));
    }
    if (Platform.isAndroid && isDemo) return (music: [demoFolder], download: demoFolder);
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

  /// Re-reads every setting (after restoring a backup).
  Future<void> reload() async => state = await AppSettings.load(_db);

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

  void setNormalizeVolume(bool v) {
    state = state.copyWith(normalizeVolume: v);
    _db.setSetting('normalize_volume', '$v');
  }

  void setAutoScanNewFolders(bool v) {
    state = state.copyWith(autoScanNewFolders: v);
    _db.setSetting('auto_scan_new_folders', '$v');
  }

  void setNormalizeLevel(NormalizeLevel v) {
    state = state.copyWith(normalizeLevel: v);
    _db.setSetting('normalize_level', v.name);
  }

  void setPodcastSpeed(double v) {
    state = state.copyWith(podcastSpeed: v);
    _db.setSetting('podcast_speed', '$v');
  }

  void setPodcastSkipSilence(bool v) {
    state = state.copyWith(podcastSkipSilence: v);
    _db.setSetting('podcast_skip_silence', '$v');
  }

  void setContinueAfterQueue(bool v) {
    state = state.copyWith(continueAfterQueue: v);
    _db.setSetting('continue_after_queue', '$v');
  }

  void setSeekSeconds(int v) {
    state = state.copyWith(seekSeconds: v);
    _db.setSetting('seek_seconds', '$v');
  }

  void setEqEnabled(bool v) {
    state = state.copyWith(eqEnabled: v);
    _db.setSetting('eq_enabled', '$v');
  }

  void setEqPreset(String v) {
    state = state.copyWith(eqPreset: v);
    _db.setSetting('eq_preset', v);
  }

  /// Moving a slider switches to 自訂.
  void setEqCustom(List<double> v) {
    state = state.copyWith(eqCustom: v, eqPreset: 'custom');
    _db.setSetting('eq_custom', v.join(','));
    _db.setSetting('eq_preset', 'custom');
  }

  void setFadeMs(int v) {
    state = state.copyWith(fadeMs: v);
    _db.setSetting('fade_ms', '$v');
  }

  void setLyricsScale(double v) {
    state = state.copyWith(lyricsScale: v);
    _db.setSetting('lyrics_scale', '$v');
  }

  void setLyricsKeepAwake(bool v) {
    state = state.copyWith(lyricsKeepAwake: v);
    _db.setSetting('lyrics_keep_awake', '$v');
  }

  /// The user's own artist names (歌手頁 →「重新命名歌手」); every artist
  /// list refreshes.
  Future<void> setArtistRenames(Map<String, String> names) async {
    ArtistRenames.set(names);
    await _db.setSetting('artist_renames', jsonEncode(names));
    _db.notifyChanged();
  }

  void setAutoUpdateCheck(bool v) {
    state = state.copyWith(autoUpdateCheck: v);
    _db.setSetting('auto_update_check', '$v');
  }

  void setArtistImagesOnline(bool v) {
    state = state.copyWith(artistImagesOnline: v);
    _db.setSetting('artist_images_online', '$v');
  }

  void setLyricsInMetadata(bool v) {
    state = state.copyWith(lyricsInMetadata: v);
    _db.setSetting('lyrics_in_metadata', '$v');
  }

  void setIconFollowTheme(bool v) {
    state = state.copyWith(iconFollowTheme: v);
    _db.setSetting('icon_follow_theme', '$v');
  }

  void setLyricsOnDownload(bool v) {
    state = state.copyWith(lyricsOnDownload: v);
    _db.setSetting('lyrics_on_download', '$v');
  }

  void setLyricsInCar(bool v) {
    state = state.copyWith(lyricsInCar: v);
    _db.setSetting('lyrics_in_car', '$v');
  }

  void setRecordPlays(bool v) {
    state = state.copyWith(recordPlays: v);
    _db.setSetting('record_plays', '$v');
  }

  void setYtAutoUpdate(bool v) {
    state = state.copyWith(ytAutoUpdate: v);
    _db.setSetting('yt_auto_update', '$v');
  }

  void setYtLastUpdate(DateTime v) {
    state = state.copyWith(ytLastUpdate: v);
    _db.setSetting('yt_last_update', v.toIso8601String());
  }

  void setWifiWarning(bool v) {
    state = state.copyWith(wifiWarning: v);
    _db.setSetting('wifi_warning', '$v');
  }

  void setSmartListShown(String name, bool shown) {
    final hidden = {...state.hiddenSmartLists};
    shown ? hidden.remove(name) : hidden.add(name);
    state = state.copyWith(hiddenSmartLists: hidden);
    _db.setSetting('hidden_smart_lists', hidden.join(','));
  }

  void setDeletePermanently(bool v) {
    state = state.copyWith(deletePermanently: v);
    _db.setSetting('delete_permanently', '$v');
  }

  void setLyricsOnline(bool v) {
    state = state.copyWith(lyricsOnline: v);
    _db.setSetting('lyrics_online', '$v');
  }

  void setAutoCleanMissing(bool v) {
    state = state.copyWith(autoCleanMissing: v);
    _db.setSetting('auto_clean_missing', '$v');
  }

  void setAllowPlaylistDuplicates(bool v) {
    state = state.copyWith(allowPlaylistDuplicates: v);
    _db.setSetting('allow_playlist_duplicates', '$v');
  }

  /// Stored only in the local database, never in source code.
  void setYoutubeApiKey(String v) {
    state = state.copyWith(youtubeApiKey: v.trim());
    _db.setSetting('youtube_api_key', v.trim());
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

/// A list's saved sort choice (encoded [TrackSort] or [GroupSort]), by scope
/// such as 'songs', 'albums', 'playlist', 'favorites'.
class SortNotifier extends Notifier<String?> {
  SortNotifier(this.scope);
  final String scope;

  @override
  String? build() => ref.read(initialSettingsProvider).sorts[scope];

  void set(String v) {
    state = v;
    ref.read(dbProvider).setSetting('sort_$scope', v);
  }
}

final sortProvider = NotifierProvider.family<SortNotifier, String?, String>(SortNotifier.new);

// ---------- library ----------
final tracksProvider = FutureProvider<List<Track>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(dbProvider).tracks();
});
/// Library entries for music folders: one per folder on Windows (named after
/// the folder), a single 「本地音樂」 on Android.
final libraryFoldersProvider = FutureProvider<List<LibraryFolder>>((ref) async {
  ref.watch(dbRevisionProvider);
  final db = ref.watch(dbProvider);
  if (Platform.isAndroid) {
    return [LibraryFolder(null, '本地音樂', (await db.tracks()).length)];
  }
  final dirs = ref.watch(settingsProvider.select((s) => s.musicDirs));
  return [
    for (final d in dirs) LibraryFolder(d, p.basename(d).isEmpty ? d : p.basename(d), await db.folderTrackCount(d)),
  ];
});
final folderTracksProvider = FutureProvider.family<List<Track>, String?>((ref, folder) {
  ref.watch(dbRevisionProvider);
  final db = ref.watch(dbProvider);
  return folder == null ? db.tracks() : db.folderTracks(folder);
});
final albumsProvider = FutureProvider<List<Album>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(dbProvider).albums();
});
final recentAlbumsProvider = FutureProvider<List<Album>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(dbProvider).recentAlbums();
});
final artistImagesProvider = Provider<ArtistImages>((ref) => ArtistImages());

/// An artist's photo (Deezer), cached on the device; null if none.
final artistImageProvider = FutureProvider.family<String?, String>((ref, name) {
  final online = ref.watch(settingsProvider.select((s) => s.artistImagesOnline));
  return ref.read(artistImagesProvider).image(name, online: online);
}, retry: (_, __) => null);

final artistsProvider = FutureProvider<List<Artist>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(dbProvider).artists();
});
final playlistsProvider = FutureProvider<List<Playlist>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(dbProvider).playlists();
});

/// Playlists not inside any folder (library list and desktop sidebar).
final topLevelPlaylistsProvider = FutureProvider<List<Playlist>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(dbProvider).playlists(topLevel: true);
});
final folderPlaylistsProvider = FutureProvider.family<List<Playlist>, int>((ref, folder) {
  ref.watch(dbRevisionProvider);
  return ref.watch(dbProvider).playlists(folder: folder);
});
final playlistFoldersProvider = FutureProvider<List<PlaylistFolder>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(dbProvider).folders();
});
final playlistInfoProvider = FutureProvider.family<Playlist?, int>((ref, id) async {
  final all = await ref.watch(playlistsProvider.future);
  return all.where((p) => p.id == id).firstOrNull;
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
final smartTracksProvider = FutureProvider.family<List<Track>, SmartList>((ref, kind) {
  ref.watch(dbRevisionProvider);
  return ref.watch(dbProvider).smartTracks(kind);
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
final podcastProgressProvider = FutureProvider((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(dbProvider).podcastProgress();
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
final shuffleProvider = StreamProvider<bool>((ref) => ref.watch(audioHandlerProvider).shuffleStream);

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

/// What the Search page shows, kept here so it survives switching tabs.
class SearchState {
  final String text;
  final bool online;

  /// The online tab looks for podcasts instead of songs.
  final bool podcast;

  /// Online searches run on submit, so this can lag behind [text].
  final String onlineQuery;
  const SearchState({this.text = '', this.online = false, this.podcast = false, this.onlineQuery = ''});

  SearchState copyWith({String? text, bool? online, bool? podcast, String? onlineQuery}) => SearchState(
      text: text ?? this.text,
      online: online ?? this.online,
      podcast: podcast ?? this.podcast,
      onlineQuery: onlineQuery ?? this.onlineQuery);
}

class SearchStateNotifier extends Notifier<SearchState> {
  @override
  SearchState build() => const SearchState();

  void setText(String v) => state = state.copyWith(text: v);
  void setOnline(bool v, {bool podcast = false}) => state = state.copyWith(online: v, podcast: v && podcast);
  void setOnlineQuery(String v) => state = state.copyWith(onlineQuery: v);
  void clear() => state = SearchState(online: state.online, podcast: state.podcast);
}

final searchStateProvider = NotifierProvider<SearchStateNotifier, SearchState>(SearchStateNotifier.new);
