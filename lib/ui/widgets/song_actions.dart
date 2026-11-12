import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../pages/cover_fix_page.dart';
import '../pages/lyrics_batch_page.dart';
import '../pages/native_name_page.dart';
import 'batch_edit_dialog.dart';
import 'dialogs.dart';
import 'download_actions.dart';
import 'edit_track_dialog.dart';
import 'export_sheet.dart';
import 'folder_actions.dart';
import 'manage_media_tile.dart' show offerAllFilesAccess;
import 'track_tile.dart' show deleteTrackFiles, removalLines;

/// One entry of the song menu.
class SongAction {
  const SongAction(this.id, this.label, {this.danger = false});
  final String id;
  final String label;
  final bool danger;
}

bool _isLocal(Track t) => t.source == TrackSource.local || t.source == TrackSource.download;

/// The song menu, the same for one song (⋮, the player) and for selected
/// songs: what applies to [tracks]. [removeLabel]: 從此播放清單移除 and the
/// like, when the list can take songs out.
List<SongAction> songActions(WidgetRef ref, List<Track> tracks, {String? removeLabel}) {
  final local = tracks.where(_isLocal).length;
  final many = tracks.length > 1;
  String n(String s) => many ? '$s（$local 首）' : s;
  final favs = ref.read(favoriteIdsProvider).value ?? const <String>{};
  final allLiked = tracks.isNotEmpty && tracks.every((t) => favs.contains(t.id));
  return [
    const SongAction('queue', '加入佇列'),
    const SongAction('playlist', '加入播放清單'),
    SongAction('like', allLiked ? '從已按讚的歌曲移除' : '加到已按讚的歌曲'),
    if (removeLabel != null) SongAction('remove', removeLabel),
    const SongAction('export', '複製／匯出資訊'),
    if (local > 0) ...[
      SongAction('edit', n('編輯資訊')),
      SongAction('covers', n('找正式封面')),
      SongAction('move', n('移到資料夾…')),
      SongAction('lyrics', n('找歌詞')),
      SongAction('native', n('找原文歌名')),
      SongAction('hide', n('從音樂庫隱藏')),
      SongAction('delete', n(ref.read(settingsProvider).deletePermanently ? '永久刪除檔案' : '刪除檔案'), danger: true),
    ],
  ];
}

/// Does [id] for [tracks]. [onRemove]: takes them out of the list shown.
/// True when the action went through (a selection then clears).
Future<bool> runSongAction(BuildContext context, WidgetRef ref, String id, List<Track> tracks,
    {Future<void> Function()? onRemove, String? removeLabel}) async {
  final handler = ref.read(audioHandlerProvider);
  final db = ref.read(dbProvider);
  final local = tracks.where(_isLocal).toList();
  final count = tracks.length == 1 ? '' : ' ${tracks.length} 首';
  // 試聽 songs are a short-lived address: ♥ and 加入播放清單 download them.
  final preview = tracks.length == 1 ? previewSourceOf(tracks.single.id) : null;
  // Changing files: once, offer 所有檔案存取權 so Android stops asking.
  if (Platform.isAndroid && const {'edit', 'covers', 'move', 'native', 'delete'}.contains(id)) await offerAllFilesAccess(context, ref);
  if (!context.mounted) return false;
  switch (id) {
    case 'queue':
      await handler.enqueue(tracks);
      if (context.mounted) toast(context, '已加入佇列');
    case 'playlist':
      if (preview != null) {
        await downloadPreview(context, preview, like: false);
      } else {
        await showAddToPlaylist(context, ref, tracks);
      }
    case 'like':
      if (preview != null) {
        await downloadPreview(context, preview, like: true);
        return true;
      }
      final favs = ref.read(favoriteIdsProvider).value ?? const <String>{};
      final unlike = tracks.every((t) => favs.contains(t.id));
      for (final t in tracks) {
        await db.setFavorite(t, !unlike);
      }
      if (context.mounted && tracks.length > 1) toast(context, unlike ? '已從已按讚的歌曲移除' : '已加到已按讚的歌曲');
    case 'remove':
      if (onRemove == null) return false;
      if (!await confirmDelete(context, title: '${removeLabel ?? '從此播放清單移除'}$count？', message: tracks.length == 1 ? tracks.single.title : null)) return false;
      await onRemove();
      if (context.mounted && tracks.length > 1) toast(context, '已移除${tracks.length} 首');
    case 'export':
      await showExportSheet(context, tracks.length == 1 ? tracks.single.title : '已選的 ${tracks.length} 首', tracks);
    case 'edit':
      // One song: the full editor (cover included); several: the batch one.
      local.length == 1 ? await showEditTrack(context, ref, local.single) : await showBatchEdit(context, ref, local);
    case 'covers':
      await Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => CoverFixPage(tracks: local)));
    case 'move':
      return moveTracksDialog(context, ref, local);
    case 'lyrics':
      await findLyrics(context, ref, [...local], title: tracks.length == 1 ? tracks.single.title : '已選的 ${local.length} 首');
    case 'native':
      await findNativeNames(context, ref, [...local]);
    case 'hide':
      final where = await removalLines(ref, local);
      if (!context.mounted) return false;
      if (!await confirmDelete(context,
          title: '從音樂庫隱藏${local.length == 1 ? '' : ' ${local.length} 首'}？',
          message: '檔案不會刪除，重新掃描後會再出現。將從以下地方移除：\n${where.map((l) => '• $l').join('\n')}',
          action: '隱藏')) {
        return false;
      }
      for (final t in local) {
        await handler.removeTrack(t.id);
      }
      await db.deleteTracks(local.map((t) => t.id));
      if (context.mounted) toast(context, '已隱藏${local.length == 1 ? '' : ' ${local.length} 首'}');
    case 'delete':
      return deleteTrackFiles(context, ref, local);
  }
  return true;
}

/// The menu for one song as a sheet of rows (⋮ and the player).
Future<void> showSongMenu(BuildContext context, WidgetRef ref, Track track, {Future<void> Function()? onRemove, String? removeLabel}) async {
  final actions = songActions(ref, [track], removeLabel: onRemove == null ? null : (removeLabel ?? '從此播放清單移除'));
  final picked = await showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const Divider(),
          for (final a in actions)
            ListTile(
              title: Text(a.label, style: a.danger ? const TextStyle(color: Colors.redAccent) : null),
              onTap: () => Navigator.pop(ctx, a.id),
            ),
        ]),
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  await runSongAction(context, ref, picked, [track], onRemove: onRemove, removeLabel: removeLabel);
}
