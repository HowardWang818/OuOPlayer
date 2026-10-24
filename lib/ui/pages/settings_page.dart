import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../providers/providers.dart';
import '../widgets/dialogs.dart';
import '../widgets/missing_files_dialog.dart';
import 'backup_page.dart';
import '../../services/updater.dart';
import 'settings/about_settings.dart';
import 'settings/devices_settings.dart';
import 'settings/download_settings.dart';
import 'settings/history_settings.dart';
import 'settings/library_settings.dart';
import 'settings/lyrics_settings.dart';
import 'settings/playback_settings.dart';
import 'settings/playlist_settings.dart';
import 'settings/podcast_settings.dart';
import 'storage_page.dart';

Future<bool> ensureStoragePermission() async {
  if (!Platform.isAndroid) return true;
  final audio = await Permission.audio.request();
  if (audio.isGranted) return true;
  // Android 12 and lower use the legacy storage permission.
  final storage = await Permission.storage.request();
  return storage.isGranted;
}

Future<void> rescanLibrary(BuildContext context, WidgetRef ref) async {
  if (!await ensureStoragePermission()) {
    if (context.mounted) toast(context, '需要音樂檔案存取權限才能掃描');
    return;
  }
  final s = ref.read(settingsProvider);
  final dirs = {...s.musicDirs, s.downloadDir}.toList();
  final added = await ref.read(scannerProvider).scan(dirs);
  if (!context.mounted) return;
  toast(context, '掃描完成，新增 $added 首歌曲');
  await checkMissingFiles(context, ref);
}

/// 設定: one row per category (like Spotify); the settings are inside.
/// Light / dark is switched with the sun / moon on the home screen.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    Widget section(IconData icon, String title, String subtitle, Widget page) => ListTile(
          leading: Icon(icon),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: muted)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        section(Icons.library_music_outlined, '音樂庫', '音樂資料夾、掃描、檢查已不存在的歌曲、刪除方式、封面與歌手圖片', const LibrarySettingsPage()),
        section(Icons.play_circle_outline, '播放', '等化器、淡入淡出、音量標準化、睡眠計時器', const PlaybackSettingsPage()),
        section(Icons.podcasts, 'Podcast', '播放速度、跳過靜音、快轉秒數', const PodcastSettingsPage()),
        section(Icons.lyrics_outlined, '歌詞', '自動找歌詞、字體大小、螢幕常亮、車上顯示', const LyricsSettingsPage()),
        section(Icons.queue_music, '播放清單', '智慧播放清單、允許重複', const PlaylistSettingsPage()),
        section(Icons.download_outlined, '下載與線上', '下載位置、Wi-Fi 提醒、yt-dlp、YouTube 金鑰', const DownloadSettingsPage()),
        if (Platform.isAndroid) section(Icons.bluetooth_audio, '藍牙與車用', '自動播放、藍牙裝置、Android Auto', const DevicesSettingsPage()),
        section(Icons.history, '播放紀錄與統計', '播放紀錄、收聽統計、清除資料', const HistorySettingsPage()),
        section(Icons.backup_outlined, '備份與還原', '手動備份、自動備份、從備份清單還原', const BackupPage()),
        section(Icons.storage_outlined, '儲存空間', '封面、歌手圖片、歌詞、下載暫存檔佔用的空間', const StoragePage()),
        const Divider(),
        section(Icons.info_outline, '關於與更新', '版本 0.18.2${Updater.supported ? ' • 檢查更新' : ''}', const AboutSettingsPage()),
      ]),
    );
  }
}
