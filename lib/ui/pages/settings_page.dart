import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../../data/db/database.dart';
import '../../providers/providers.dart';
import '../../services/equalizer.dart';
import '../../services/sleep_timer.dart';
import '../widgets/dialogs.dart';
import '../widgets/backup_actions.dart';
import '../widgets/missing_files_dialog.dart';
import '../../services/missing_files.dart';
import '../../services/file_trash.dart';
import '../widgets/sleep_timer_sheet.dart';
import 'devices_page.dart';
import 'equalizer_page.dart';
import 'storage_page.dart';
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
  if (!context.mounted) return;
  toast(context, '掃描完成，新增 $added 首歌曲');
  await checkMissingFiles(context, ref);
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
              onPressed: () async {
                if (await confirmDelete(context,
                    title: '移除音樂資料夾？', message: '$d\n\n資料夾和裡面的檔案不會被刪除，只是 OuOPlayer 不再掃描它。')) {
                  n.setMusicDirs([...s.musicDirs]..remove(d));
                }
              },
            ),
          ),
        ListTile(
          leading: const Icon(Icons.create_new_folder_outlined),
          title: const Text('新增資料夾'),
          onTap: () async {
            await ensureStoragePermission();
            final dir = await FilePicker.getDirectoryPath(dialogTitle: '選擇音樂資料夾');
            if (dir == null) return;
            final cover = coveringFolder(dir, {...s.musicDirs, s.downloadDir});
            if (cover != null) {
              if (context.mounted) toast(context, cover == dir ? '這個資料夾已經在清單裡' : '已包含在「$cover」裡，不需要另外加入');
              return;
            }
            n.setMusicDirs([...s.musicDirs, dir]);
            if (ref.read(settingsProvider).autoScanNewFolders) {
              final added = await ref.read(scannerProvider).scan([dir]);
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
        ListTile(
          leading: const Icon(Icons.graphic_eq),
          title: const Text('等化器'),
          subtitle: Text(s.eqEnabled ? '已開啟：${EqPreset.byName(s.eqPreset).label}' : '關閉'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EqualizerPage())),
        ),
        ListTile(
          leading: const Icon(Icons.blur_linear),
          title: const Text('播放／暫停淡入淡出'),
          subtitle: Text(s.fadeMs == 0 ? '關閉' : '${s.fadeMs / 1000} 秒（換歌時不淡出）'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
          child: SegmentedButton<int>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 0, label: Text('關')),
              ButtonSegment(value: 300, label: Text('0.3')),
              ButtonSegment(value: 500, label: Text('0.5')),
              ButtonSegment(value: 1000, label: Text('1')),
              ButtonSegment(value: 2000, label: Text('2')),
            ],
            selected: {s.fadeMs},
            onSelectionChanged: (v) => n.setFadeMs(v.first),
          ),
        ),
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
        header('歌詞'),
        SwitchListTile(
          secondary: const Icon(Icons.lyrics_outlined),
          title: const Text('自動上網找歌詞'),
          subtitle: const Text('歌曲檔案和 .lrc 檔都沒有歌詞時，從 LRCLIB 查詢（免費，只會送出歌名、歌手、專輯和長度）'),
          value: s.lyricsOnline,
          onChanged: n.setLyricsOnline,
        ),
        header('備份與還原'),
        ListTile(
          leading: const Icon(Icons.backup_outlined),
          title: const Text('備份資料'),
          subtitle: const Text('播放清單、資料夾、已按讚的歌曲、播放次數、Podcast 和設定，存成一個檔案（不含 YouTube 金鑰）'),
          onTap: () => exportBackup(context, ref),
        ),
        ListTile(
          leading: const Icon(Icons.settings_backup_restore),
          title: const Text('從備份還原'),
          subtitle: const Text('會取代目前的資料，還原前會先確認'),
          onTap: () => importBackup(context, ref),
        ),
        ListTile(
          leading: const Icon(Icons.format_size),
          title: const Text('歌詞字體大小'),
          subtitle: Text('預覽：這是一行歌詞', style: TextStyle(fontSize: 16 * s.lyricsScale, fontWeight: FontWeight.bold)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(56, 0, 16, 0),
          child: Slider(
            min: 0.8,
            max: 1.6,
            divisions: 8,
            label: '${(s.lyricsScale * 100).round()}%',
            value: s.lyricsScale.clamp(0.8, 1.6),
            onChanged: (v) => n.setLyricsScale(double.parse(v.toStringAsFixed(1))),
          ),
        ),
        if (Platform.isAndroid)
          SwitchListTile(
            secondary: const Icon(Icons.light_mode_outlined),
            title: const Text('顯示歌詞時螢幕保持常亮'),
            value: s.lyricsKeepAwake,
            onChanged: n.setLyricsKeepAwake,
          ),
        header('音樂庫維護'),
        SwitchListTile(
          secondary: const Icon(Icons.cleaning_services_outlined),
          title: const Text('自動檢查已不存在的歌曲'),
          subtitle: const Text('開啟 App 和切回 App 時檢查；發現檔案已不存在的歌曲時，先問你再從音樂庫移除'),
          value: s.autoCleanMissing,
          onChanged: n.setAutoCleanMissing,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.delete_forever_outlined),
          title: const Text('刪除檔案時直接永久刪除'),
          subtitle: Text(s.deletePermanently
              ? '已開啟：刪除的檔案無法還原。不是 OuOPlayer 下載的檔案，系統會再請你確認一次'
              : '關閉時，刪除的檔案會移到$trashName，可以還原'),
          value: s.deletePermanently,
          onChanged: n.setDeletePermanently,
        ),
        ListTile(
          leading: const Icon(Icons.storage_outlined),
          title: const Text('儲存空間'),
          subtitle: const Text('封面、歌詞、下載暫存檔佔用的空間，可以清除'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const StoragePage())),
        ),
        ListTile(
          leading: const Icon(Icons.search),
          title: const Text('立即檢查已不存在的歌曲'),
          onTap: () => checkMissingFiles(context, ref, manual: true),
        ),
        header('播放清單'),
        ExpansionTile(
          leading: const Icon(Icons.auto_awesome_outlined),
          title: const Text('顯示智慧播放清單'),
          subtitle: Text('顯示 ${SmartList.values.where((l) => !s.hiddenSmartLists.contains(l.name)).length} / ${SmartList.values.length} 個'),
          children: [
            for (final l in SmartList.values)
              SwitchListTile(
                contentPadding: const EdgeInsets.only(left: 72, right: 16),
                title: Text(l.label),
                subtitle: Text(l.description),
                value: !s.hiddenSmartLists.contains(l.name),
                onChanged: (v) => n.setSmartListShown(l.name, v),
              ),
          ],
        ),
        SwitchListTile(
          secondary: const Icon(Icons.copy_all_outlined),
          title: const Text('允許歌曲重複'),
          subtitle: const Text('手動加入播放清單時，同一首歌可以加第二次。下載播放清單時不會重複加入。'),
          value: s.allowPlaylistDuplicates,
          onChanged: n.setAllowPlaylistDuplicates,
        ),
        header('線上搜尋'),
        ListTile(
          leading: const Icon(Icons.key_outlined),
          title: const Text('YouTube Data API 金鑰'),
          subtitle: Text(s.youtubeApiKey.isEmpty ? '未設定（用於「取得 YouTube Music 連結」）' : '已設定 •••${s.youtubeApiKey.substring(s.youtubeApiKey.length > 4 ? s.youtubeApiKey.length - 4 : 0)}',
              style: TextStyle(color: muted)),
          trailing: TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const YouTubeKeyGuidePage())),
            child: const Text('如何申請？'),
          ),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const YouTubeKeyGuidePage())),
        ),
        header('下載'),
        SwitchListTile(
          secondary: const Icon(Icons.system_update_alt),
          title: const Text('自動更新 yt-dlp'),
          subtitle: Text(
              '每 7 天在背景檢查一次${s.ytLastUpdate == null ? '' : '（上次：${s.ytLastUpdate!.month}/${s.ytLastUpdate!.day}）'}。開啟「沒有 Wi-Fi 時下載前提醒」時只在 Wi-Fi 下更新'),
          value: s.ytAutoUpdate,
          onChanged: n.setYtAutoUpdate,
        ),
        if (Platform.isAndroid)
          SwitchListTile(
            secondary: const Icon(Icons.wifi_off_outlined),
            title: const Text('沒有 Wi-Fi 時下載前提醒'),
            subtitle: const Text('使用行動數據時，開始下載前先問你'),
            value: s.wifiWarning,
            onChanged: n.setWifiWarning,
          ),
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
        const ListTile(leading: Icon(Icons.info_outline), title: Text('OuOPlayer'), subtitle: Text('版本 0.11.1')),
      ]),
    );
  }
}
