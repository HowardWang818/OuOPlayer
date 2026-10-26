import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../providers/providers.dart';
import '../../../services/file_trash.dart';
import '../../../services/missing_files.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/manage_media_tile.dart';
import '../../widgets/missing_files_dialog.dart';
import '../cover_fix_page.dart';
import '../native_name_page.dart';
import '../settings_page.dart';
import 'section_page.dart';

/// 音樂庫: music folders, scanning, missing songs, deleting, covers and artist photos.
class LibrarySettingsPage extends ConsumerWidget {
  const LibrarySettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final scan = ref.watch(scanProgressProvider).value;
    return SettingsSectionPage(title: '音樂庫', children: [
      settingsSubheader(context, '音樂資料夾'),
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
      settingsSubheader(context, '維護'),
      SwitchListTile(
        secondary: const Icon(Icons.cleaning_services_outlined),
        title: const Text('自動檢查已不存在的歌曲'),
        subtitle: const Text('開啟 App 和切回 App 時檢查；發現檔案已不存在的歌曲時，先問你再從音樂庫移除'),
        value: s.autoCleanMissing,
        onChanged: n.setAutoCleanMissing,
      ),
      ListTile(
        leading: const Icon(Icons.search),
        title: const Text('立即檢查已不存在的歌曲'),
        onTap: () => checkMissingFiles(context, ref, manual: true),
      ),
      if (Platform.isAndroid) const ManageMediaTile(),
      SwitchListTile(
        secondary: const Icon(Icons.delete_forever_outlined),
        title: const Text('刪除檔案時直接永久刪除'),
        subtitle: Text(s.deletePermanently
            ? '已開啟：刪除的檔案無法還原。不是 OuOPlayer 下載的檔案，系統會再請你確認一次'
            : '關閉時，刪除的檔案會移到$trashName，可以還原'),
        value: s.deletePermanently,
        onChanged: n.setDeletePermanently,
      ),
      if (s.homeHidden.isNotEmpty)
        ListTile(
          leading: const Icon(Icons.restore),
          title: const Text('還原首頁捷徑'),
          subtitle: Text('從首頁移除了 ${s.homeHidden.length} 個捷徑，選要放回首頁的'),
          onTap: () => restoreHomeShortcuts(context, ref),
        ),
      settingsSubheader(context, '封面與歌手圖片'),
      ListTile(
        leading: const Icon(Icons.image_search_outlined),
        title: const Text('整理音樂庫的封面'),
        subtitle: const Text('替沒有封面、或封面是影片截圖的歌，從 iTunes 找正式的正方形封面（會先預覽）'),
        onTap: () async {
          final all = await ref.read(dbProvider).tracks();
          if (context.mounted) await findCovers(context, ref, all);
        },
      ),
      ListTile(
        leading: const Icon(Icons.translate),
        title: const Text('找原文歌名'),
        subtitle: const Text('羅馬拼音或英文的歌名（例如 YouTube Music 下載的「Yoru ni Kakeru」）改回日文或中文的原名（會先預覽）'),
        onTap: () async {
          final all = await ref.read(dbProvider).tracks();
          if (context.mounted) await findNativeNames(context, ref, all);
        },
      ),
      SwitchListTile(
        secondary: const Icon(Icons.person_search_outlined),
        title: const Text('自動上網找歌手圖片'),
        subtitle: Text('從 Deezer 下載歌手照片（免費，只會送出歌手名字），存在${Platform.isAndroid ? '手機' : '電腦'}上'),
        value: s.artistImagesOnline,
        onChanged: n.setArtistImagesOnline,
      ),
    ]);
  }
}

/// Lists the shortcuts taken off the home page; the ticked ones go back.
Future<void> restoreHomeShortcuts(BuildContext context, WidgetRef ref) async {
  final hidden = [...ref.read(settingsProvider).homeHidden];
  final playlists = await ref.read(dbProvider).playlists();
  if (!context.mounted) return;
  String label(String k) {
    if (k.startsWith('playlist:')) {
      final id = int.tryParse(k.substring(9));
      final name = playlists.where((p) => p.id == id).firstOrNull?.name;
      return name == null ? '（已刪除的播放清單）' : '播放清單：$name';
    }
    if (k.startsWith('album:')) return '專輯：${k.substring(6)}';
    return k;
  }

  final picked = <String>{};
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('還原首頁捷徑'),
        content: SizedBox(
          width: 400,
          child: ListView(shrinkWrap: true, children: [
            for (final k in hidden)
              CheckboxListTile(
                value: picked.contains(k),
                onChanged: (v) => setState(() => v == true ? picked.add(k) : picked.remove(k)),
                title: Text(label(k), maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: picked.isEmpty ? null : () => Navigator.pop(ctx, true), child: Text('還原 ${picked.length} 個')),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  final n = ref.read(settingsProvider.notifier);
  for (final k in picked) {
    n.setHomeHidden(k, false);
  }
  toast(context, '已還原 ${picked.length} 個首頁捷徑');
}
