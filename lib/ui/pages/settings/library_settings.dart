import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../data/models/track.dart';
import '../../../providers/providers.dart';
import '../../../services/cover_finder.dart';
import '../../../services/file_trash.dart';
import '../../../services/missing_files.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/track_tile.dart' show removalLines;
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
            onPressed: () => removeMusicFolder(context, ref, d),
          ),
        ),
      SettingTile(
        action: '新增',
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
      SettingSwitch(
        secondary: const Icon(Icons.manage_search),
        title: const Text('新增資料夾時自動掃描'),
        subtitle: const Text('並在音樂庫顯示該資料夾'),
        value: s.autoScanNewFolders,
        onChanged: n.setAutoScanNewFolders,
      ),
      SettingTile(
        action: '掃描',
        leading: const Icon(Icons.refresh),
        title: const Text('重新掃描音樂庫'),
        subtitle: scan != null && scan.running ? Text(scan.total == 0 ? '搜尋中…' : '${scan.done}/${scan.total}') : null,
        onTap: scan?.running == true ? null : () => rescanLibrary(context, ref),
      ),
      settingsSubheader(context, '維護'),
      SettingSwitch(
        secondary: const Icon(Icons.cleaning_services_outlined),
        title: const Text('自動檢查已不存在的歌曲'),
        subtitle: const Text('開啟 App 和切回 App 時檢查；發現檔案已不存在的歌曲時，先問你再從音樂庫移除'),
        value: s.autoCleanMissing,
        onChanged: n.setAutoCleanMissing,
      ),
      SettingTile(
        action: '檢查',
        leading: const Icon(Icons.search),
        title: const Text('立即檢查已不存在的歌曲'),
        onTap: () => checkMissingFiles(context, ref, manual: true),
      ),
      if (Platform.isAndroid) const ManageMediaTile(),
      SettingSwitch(
        secondary: const Icon(Icons.delete_forever_outlined),
        title: const Text('刪除檔案時直接永久刪除'),
        subtitle: Text(s.deletePermanently
            ? '已開啟：刪除的檔案無法還原。不是 OuOPlayer 下載的檔案，系統會再請你確認一次'
            : '關閉時，刪除的檔案會移到$trashName，可以還原'),
        value: s.deletePermanently,
        onChanged: n.setDeletePermanently,
      ),
      if (s.homeHidden.isNotEmpty)
        SettingTile(
          action: '還原',
          leading: const Icon(Icons.restore),
          title: const Text('還原首頁捷徑'),
          subtitle: Text('從首頁移除了 ${s.homeHidden.length} 個捷徑，選要放回首頁的'),
          onTap: () => restoreHomeShortcuts(context, ref),
        ),
      const _OrphanSongsTile(),
      settingsSubheader(context, '封面與歌手圖片'),
      SettingTile(
        action: '整理',
        leading: const Icon(Icons.image_search_outlined),
        title: const Text('整理音樂庫的封面'),
        subtitle: const Text('替沒有封面、或封面是影片截圖的歌，從 iTunes 找正式的正方形封面（會先預覽）'),
        onTap: () async {
          final all = await ref.read(dbProvider).tracks();
          if (context.mounted) await findCovers(context, ref, all);
        },
      ),
      SettingTile(
        action: '替換',
        leading: const Icon(Icons.hd_outlined),
        title: const Text('替換太小的封面'),
        subtitle: const Text('小於 500×500、在電腦上看起來糊的封面，也從 iTunes 找正式封面（會先預覽）'),
        onTap: () async {
          final all = await ref.read(dbProvider).tracks();
          if (context.mounted) await findCovers(context, ref, all, small: true);
        },
      ),
      const _CoverSizeTile(),
      SettingTile(
        action: '尋找',
        leading: const Icon(Icons.translate),
        title: const Text('找原文歌名'),
        subtitle: const Text('羅馬拼音或英文的歌名（例如 YouTube Music 下載的「Yoru ni Kakeru」）改回日文或中文的原名（會先預覽）'),
        onTap: () async {
          final all = await ref.read(dbProvider).tracks();
          if (context.mounted) await findNativeNames(context, ref, all);
        },
      ),
      SettingSwitch(
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
              SettingCheck(
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

/// 移除音樂資料夾: no longer scanned, and its songs leave the library (and the
/// playlists / likes they were in: the same warning as 從音樂庫隱藏). Songs
/// another music folder or the download folder still covers stay.
Future<void> removeMusicFolder(BuildContext context, WidgetRef ref, String dir) async {
  final s = ref.read(settingsProvider);
  final db = ref.read(dbProvider);
  final keepDirs = [...s.musicDirs.where((x) => x != dir), s.downloadDir];
  bool inside(String path, String folder) {
    final a = p.normalize(path).toLowerCase(), b = p.normalize(folder).toLowerCase();
    return a == b || p.isWithin(b, a);
  }

  final songs = [
    for (final t in await db.folderTracks(dir))
      if (!keepDirs.any((k) => inside(t.uri, k)) && t.source != TrackSource.missing) t,
  ];
  final where = songs.isEmpty ? <String>[] : await removalLines(ref, songs);
  if (!context.mounted) return;
  final ok = await confirmDelete(context,
      title: '移除音樂資料夾？',
      message: '$dir\n\n資料夾和裡面的檔案不會被刪除，OuOPlayer 不再掃描它'
          '${songs.isEmpty ? '。' : '，已經掃描的 ${songs.length} 首也會從音樂庫移除。會從以下地方移除：\n${where.map((l) => '• $l').join('\n')}'}',
      action: '移除');
  if (!ok) return;
  ref.read(settingsProvider.notifier).setMusicDirs([...s.musicDirs]..remove(dir));
  if (songs.isEmpty) return;
  final handler = ref.read(audioHandlerProvider);
  for (final t in songs) {
    await handler.removeTrack(t.id);
  }
  await db.deleteTracks(songs.map((t) => t.id));
  if (context.mounted) toast(context, '已移除資料夾和 ${songs.length} 首歌');
}

/// Scanned songs no music folder covers any more (their folder was removed
/// before v1.9.0 took its songs along).
Future<List<Track>> orphanSongs(WidgetRef ref) async {
  final s = ref.read(settingsProvider);
  final dirs = [...s.musicDirs, s.downloadDir];
  bool inside(String path, String folder) {
    final a = p.normalize(path).toLowerCase(), b = p.normalize(folder).toLowerCase();
    return a == b || p.isWithin(b, a);
  }

  return [
    for (final t in await ref.read(dbProvider).tracks())
      if (t.source == TrackSource.local && !t.isRemote && t.uri.isNotEmpty && !dirs.any((d) => inside(t.uri, d))) t,
  ];
}

/// 封面大小: the size 找封面 takes from iTunes.
class _CoverSizeTile extends ConsumerStatefulWidget {
  const _CoverSizeTile();

  @override
  ConsumerState<_CoverSizeTile> createState() => _CoverSizeTileState();
}

class _CoverSizeTileState extends ConsumerState<_CoverSizeTile> {
  static const _labels = {600: '小（600×600，檔案最小）', 1200: '中（1200×1200，電腦上也清楚）', 3000: '大（3000×3000，最清楚，檔案較大）'};

  @override
  void initState() {
    super.initState();
    CoverFinder.loadSize(ref.read(dbProvider)).then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) => SettingTile(
    action: '更改',
        leading: const Icon(Icons.photo_size_select_large_outlined),
        title: const Text('封面大小'),
        subtitle: Text('找封面時從 iTunes 取用的大小：${_labels[CoverFinder.size]}'),
        onTap: () async {
          final picked = await showDialog<int>(
            context: context,
            builder: (c) => SimpleDialog(
              title: const Text('封面大小'),
              children: [
                for (final e in _labels.entries)
                  ListTile(
                    leading: Icon(e.key == CoverFinder.size ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                    title: Text(e.value),
                    onTap: () => Navigator.pop(c, e.key),
                  ),
              ],
            ),
          );
          if (picked == null) return;
          await ref.read(dbProvider).setSetting('cover_size', '$picked');
          setState(() => CoverFinder.size = picked);
        },
      );
}

class _OrphanSongsTile extends ConsumerWidget {
  const _OrphanSongsTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(settingsProvider.select((s) => s.musicDirs));
    ref.watch(dbRevisionProvider);
    return FutureBuilder<List<Track>>(
      future: orphanSongs(ref),
      builder: (context, snap) {
        final songs = snap.data ?? const [];
        if (songs.isEmpty) return const SizedBox.shrink();
        return SettingTile(
          action: '移除',
          leading: const Icon(Icons.folder_off_outlined),
          title: Text('移除不在音樂資料夾裡的歌（${songs.length} 首）'),
          subtitle: const Text('它們的資料夾已經從清單移除，但歌還留在音樂庫'),
          onTap: () async {
            final folders = {for (final t in songs) p.dirname(t.uri)}.toList()..sort();
            final where = await removalLines(ref, songs);
            if (!context.mounted) return;
            final ok = await confirmDelete(context,
                title: '從音樂庫移除 ${songs.length} 首？',
                message: '檔案不會被刪除。這些歌來自：\n${folders.take(8).map((f) => '• $f').join('\n')}${folders.length > 8 ? '\n…' : ''}'
                    '\n\n會從以下地方移除：\n${where.map((l) => '• $l').join('\n')}',
                action: '移除');
            if (!ok) return;
            final handler = ref.read(audioHandlerProvider);
            for (final t in songs) {
              await handler.removeTrack(t.id);
            }
            await ref.read(dbProvider).deleteTracks(songs.map((t) => t.id));
            if (context.mounted) toast(context, '已移除 ${songs.length} 首');
          },
        );
      },
    );
  }
}
