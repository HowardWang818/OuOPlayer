import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../../providers/providers.dart';
import '../../services/sleep_timer.dart';
import '../widgets/dialogs.dart';
import '../widgets/sleep_timer_sheet.dart';
import 'devices_page.dart';
import 'youtube_key_guide_page.dart';

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
  if (context.mounted) toast(context, '掃描完成，新增 $added 首歌曲');
}

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final scan = ref.watch(scanProgressProvider).value;

    Widget header(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(t, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        header('外觀'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode), label: Text('深色')),
              ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode), label: Text('淺色')),
              ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto), label: Text('跟隨系統')),
            ],
            selected: {s.themeMode},
            onSelectionChanged: (v) => n.setTheme(v.first),
          ),
        ),
        header('音樂資料夾'),
        for (final d in s.musicDirs)
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(d, maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => n.setMusicDirs([...s.musicDirs]..remove(d)),
            ),
          ),
        ListTile(
          leading: const Icon(Icons.create_new_folder_outlined),
          title: const Text('新增資料夾'),
          onTap: () async {
            await ensureStoragePermission();
            final dir = await FilePicker.getDirectoryPath(dialogTitle: '選擇音樂資料夾');
            if (dir == null || s.musicDirs.contains(dir)) return;
            n.setMusicDirs([...s.musicDirs, dir]);
            if (ref.read(settingsProvider).autoScanNewFolders) {
              final added = await ref.read(scannerProvider).scan([dir], removeMissing: false);
              if (context.mounted) toast(context, '「${p.basename(dir)}」掃描完成，新增 $added 首歌曲');
            }
          },
        ),
        SwitchListTile(
          secondary: const Icon(Icons.manage_search),
          title: const Text('新增資料夾時自動掃描'),
          subtitle: const Text('並在音樂庫顯示該資料夾'),
          value: s.autoScanNewFolders,
          onChanged: n.setAutoScanNewFolders,
        ),
        ListTile(
          leading: const Icon(Icons.refresh),
          title: const Text('重新掃描音樂庫'),
          subtitle: scan != null && scan.running ? Text(scan.total == 0 ? '搜尋中…' : '${scan.done}/${scan.total}') : null,
          onTap: scan?.running == true ? null : () => rescanLibrary(context, ref),
        ),
        header('播放'),
        SwitchListTile(
          secondary: const Icon(Icons.equalizer),
          title: const Text('音量標準化'),
          subtitle: const Text('讓每首歌聽起來一樣大聲'),
          value: s.normalizeVolume,
          onChanged: n.setNormalizeVolume,
        ),
        if (s.normalizeVolume)
          Padding(
            padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
            child: SegmentedButton<NormalizeLevel>(
              segments: [for (final l in NormalizeLevel.values) ButtonSegment(value: l, label: Text(l.label))],
              selected: {s.normalizeLevel},
              onSelectionChanged: (v) => n.setNormalizeLevel(v.first),
            ),
          ),
        ListTile(
          leading: const Icon(Icons.speed),
          title: const Text('Podcast 播放速度'),
          subtitle: const Text('音樂一律以原速播放'),
          trailing: DropdownButton<double>(
            value: s.podcastSpeed,
            underline: const SizedBox(),
            items: [for (final v in podcastSpeeds) DropdownMenuItem(value: v, child: Text('${v}x'))],
            onChanged: (v) => n.setPodcastSpeed(v!),
          ),
        ),
        if (Platform.isAndroid)
          SwitchListTile(
            secondary: const Icon(Icons.content_cut),
            title: const Text('Podcast 跳過靜音'),
            subtitle: const Text('自動略過沒有聲音的段落'),
            value: s.podcastSkipSilence,
            onChanged: n.setPodcastSkipSilence,
          ),
        ListTile(
          leading: const Icon(Icons.bedtime_outlined),
          title: const Text('睡眠計時器'),
          subtitle: Text(sleepTimerLabel(ref.watch(sleepTimerProvider))),
          onTap: () => showSleepTimerSheet(context, ref),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.all_inclusive),
          title: const Text('佇列播完後繼續播放'),
          subtitle: const Text('從音樂庫隨機接著播放'),
          value: s.continueAfterQueue,
          onChanged: n.setContinueAfterQueue,
        ),
        const ListTile(
          leading: Icon(Icons.fast_forward_outlined),
          title: Text('快轉 / 倒轉秒數'),
          subtitle: Text('播放 Podcast 時使用'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
          child: SegmentedButton<int>(
            segments: [for (final v in seekSecondOptions) ButtonSegment(value: v, label: Text('$v 秒'))],
            selected: {s.seekSeconds},
            onSelectionChanged: (v) => n.setSeekSeconds(v.first),
          ),
        ),
        header('線上搜尋'),
        ListTile(
          leading: const Icon(Icons.key_outlined),
          title: const Text('YouTube Data API 金鑰'),
          subtitle: Text(s.youtubeApiKey.isEmpty ? '未設定（用於「取得 YouTube 連結」）' : '已設定 •••${s.youtubeApiKey.substring(s.youtubeApiKey.length > 4 ? s.youtubeApiKey.length - 4 : 0)}',
              style: TextStyle(color: muted)),
          trailing: TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const YouTubeKeyGuidePage())),
            child: const Text('如何申請？'),
          ),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const YouTubeKeyGuidePage())),
        ),
        header('下載'),
        ListTile(
          leading: const Icon(Icons.download_outlined),
          title: const Text('下載位置'),
          subtitle: Text(s.downloadDir, style: TextStyle(color: muted)),
          onTap: () async {
            final dir = await FilePicker.getDirectoryPath(dialogTitle: '選擇下載位置');
            if (dir != null) n.setDownloadDir(dir);
          },
        ),
        if (Platform.isAndroid) ...[
          header('藍牙'),
          SwitchListTile(
            secondary: const Icon(Icons.bluetooth_audio),
            title: const Text('藍牙耳機連線時自動播放'),
            subtitle: const Text('接續上次的播放佇列；斷線時一律自動暫停'),
            value: s.btAutoPlay,
            onChanged: n.setBtAutoPlay,
          ),
          ListTile(
            leading: const Icon(Icons.devices),
            title: const Text('藍牙裝置'),
            subtitle: const Text('掃描、配對與連接'),
            onTap: () => Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => const DevicesPage())),
          ),
        ],
        header('關於'),
        const ListTile(leading: Icon(Icons.info_outline), title: Text('OuOPlayer'), subtitle: Text('版本 0.3.0')),
      ]),
    );
  }
}
