import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';
import '../youtube_key_guide_page.dart';
import 'section_page.dart';

/// 下載與線上: where downloads go, mobile data, yt-dlp and the YouTube key.
class DownloadSettingsPage extends ConsumerWidget {
  const DownloadSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return SettingsSectionPage(title: '下載與線上', children: [
      SettingTile(
        action: '更改',
        leading: const Icon(Icons.download_outlined),
        title: const Text('下載位置'),
        subtitle: Text(s.downloadDir, style: TextStyle(color: muted)),
        onTap: () async {
          final dir = await FilePicker.getDirectoryPath(dialogTitle: '選擇下載位置');
          if (dir != null) n.setDownloadDir(dir);
        },
      ),
      if (Platform.isAndroid)
        SettingSwitch(
          secondary: const Icon(Icons.wifi_off_outlined),
          title: const Text('沒有 Wi-Fi 時下載前提醒'),
          subtitle: const Text('使用行動數據時，開始下載前先問你'),
          value: s.wifiWarning,
          onChanged: n.setWifiWarning,
        ),
      SettingSwitch(
        secondary: const Icon(Icons.translate),
        title: const Text('下載時找原文歌名'),
        subtitle: const Text('羅馬拼音或英文的歌名（例如「Yoru ni Kakeru」）下載完改回日文或中文的原名，只有很確定時才改。每首多花幾秒'),
        value: s.nativeNamesOnDownload,
        onChanged: n.setNativeNamesOnDownload,
      ),
      SettingSwitch(
        secondary: const Icon(Icons.system_update_alt),
        title: const Text('自動更新 yt-dlp'),
        subtitle: Text(
            '每 7 天在背景檢查一次${s.ytLastUpdate == null ? '' : '（上次：${s.ytLastUpdate!.month}/${s.ytLastUpdate!.day}）'}'
            '${Platform.isAndroid ? '。開啟「沒有 Wi-Fi 時下載前提醒」時只在 Wi-Fi 下更新' : ''}'),
        value: s.ytAutoUpdate,
        onChanged: n.setYtAutoUpdate,
      ),
      SettingTile(
        leading: const Icon(Icons.key_outlined),
        title: const Text('YouTube Data API 金鑰'),
        subtitle: Text(
            s.youtubeApiKey.isEmpty
                ? '未設定（用於「取得 YouTube Music 連結」）'
                : '已設定 •••${s.youtubeApiKey.substring(s.youtubeApiKey.length > 4 ? s.youtubeApiKey.length - 4 : 0)}',
            style: TextStyle(color: muted)),
        trailing: TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const YouTubeKeyGuidePage())),
          child: const Text('如何申請？'),
        ),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const YouTubeKeyGuidePage())),
      ),
    ]);
  }
}
