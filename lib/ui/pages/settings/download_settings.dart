import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../data/models/track.dart';
import '../../../services/folder_ops.dart';
import '../../widgets/dialogs.dart';

import '../../../providers/providers.dart';
import '../../widgets/download_actions.dart' show downloadTerms;
import 'section_page.dart';
import 'tidy_names_page.dart';

/// A new download folder (1.20.15): the songs downloaded into the old one
/// may come along, keeping their playlists, likes and play counts.
Future<void> moveDownloads(BuildContext context, WidgetRef ref, String from, String to) async {
  final db = ref.read(dbProvider);
  final inside = [
    for (final t in await db.tracks())
      if (t.source == TrackSource.download && !t.isRemote && p.isWithin(from, t.uri) && !p.isWithin(to, t.uri) && File(t.uri).existsSync()) t,
  ];
  if (inside.isEmpty || !context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('搬移 ${inside.length} 首已下載的歌？'),
      content: Text('「$from」\n→「$to」'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('不搬')),
        FilledButton(autofocus: true, onPressed: () => Navigator.pop(c, true), child: const Text('搬移')),
      ],
    ),
  );
  if (ok != true) return;
  try {
    final r = await FolderOps(db).moveBetween(inside, from, to);
    if (context.mounted) toast(context, r.failed == 0 ? '已搬移 ${r.moved.length} 首' : '已搬移 ${r.moved.length} 首，${r.failed} 首沒有搬移');
  } catch (e) {
    if (context.mounted) toast(context, '搬移失敗：$e');
  }
}

/// 下載與線上: where downloads go, mobile data and yt-dlp.
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
          final old = s.downloadDir;
          final dir = await FilePicker.getDirectoryPath(dialogTitle: '選擇下載位置');
          if (dir == null) return;
          n.setDownloadDir(dir);
          if (context.mounted && !p.equals(old, dir)) await moveDownloads(context, ref, old, dir);
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
      SettingTile(
        action: '整理',
        leading: const Icon(Icons.drive_file_rename_outline),
        title: const Text('整理檔名'),
        subtitle: const Text('下載的檔名改成正式歌名'),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TidyNamesPage())),
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
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(downloadTerms, style: TextStyle(fontSize: 12, color: muted)),
      ),
    ]);
  }
}
