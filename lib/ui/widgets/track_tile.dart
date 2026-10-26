import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/file_trash.dart';
import '../../theme/app_theme.dart';
import '../pages/collection_page.dart';
import '../pages/cover_fix_page.dart';
import '../pages/missing_songs_page.dart';
import '../pages/native_name_page.dart';
import '../../services/native_names.dart';
import '../pages/pick_replacement_page.dart';
import 'art_image.dart';
import 'dialogs.dart';
import 'edit_track_dialog.dart';
import 'removal_summary.dart';
import 'track_links.dart';
import 'track_selection.dart';

class TrackTile extends ConsumerWidget {
  const TrackTile({
    super.key,
    required this.track,
    required this.onTap,
    this.index,
    this.showArt = true,
    this.onRemove,
    this.removeLabel = '從此播放清單移除',
    this.trailing,
    this.dragHandle,
    this.selectIndex,
  });

  final Track track;
  final VoidCallback onTap;
  final int? index;
  final bool showArt;
  final VoidCallback? onRemove;
  final String removeLabel;
  final Widget? trailing;

  /// Shown last, right of the ⋮ menu (a playlist's reorder handle).
  final Widget? dragHandle;

  /// Row index inside an enclosing [TrackSelectionScope]; enables long-press
  /// (or right-click) selection.
  final int? selectIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(currentTrackProvider);
    final playing = current?.uri == track.uri;
    final cs = Theme.of(context).colorScheme;
    final selection = selectIndex == null ? null : TrackSelection.maybeOf(context);
    final selecting = selection?.active ?? false;
    final selected = selecting && selection!.selected.contains(selectIndex);
    void select() {
      final keys = HardwareKeyboard.instance;
      selection!.toggle(selectIndex!, range: keys.isShiftPressed);
    }

    // Listed but not on the device: greyed, not playable.
    if (track.source == TrackSource.missing) {
      final tile = ListTile(
        selected: selected,
        selectedTileColor: AppColors.accent.withValues(alpha: 0.15),
        onTap: selecting ? select : () => showMissingSongMenu(context, ref, track, onRemove: onRemove, removeLabel: removeLabel),
        onLongPress: selection == null ? null : select,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        leading: Opacity(
          opacity: 0.4,
          child: showArt
              ? const SizedBox(width: 48, height: 48, child: Icon(Icons.music_off_outlined))
              : SizedBox(width: 32, child: Center(child: Text('${index != null ? index! + 1 : ''}'))),
        ),
        title: Text(track.title,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurface.withValues(alpha: 0.45))),
        subtitle: Text('缺少 • ${track.artist}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurfaceVariant.withValues(alpha: 0.6))),
        trailing: selecting ? null : Icon(Icons.cloud_off_outlined, color: cs.onSurfaceVariant.withValues(alpha: 0.6)),
      );
      return selection == null ? tile : GestureDetector(onSecondaryTap: select, child: tile);
    }

    final tile = ListTile(
      selected: selected,
      selectedTileColor: AppColors.accent.withValues(alpha: 0.15),
      // While selecting, a tap (or Ctrl/Shift+click on desktop) toggles the row.
      onTap: selection != null &&
              (selecting || HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isShiftPressed)
          ? select
          : onTap,
      onLongPress: selection == null ? null : select,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      // Selected rows keep their cover (or track number) with a solid check on top.
      leading: Stack(alignment: Alignment.center, children: [
        showArt
            ? ArtImage(track.art, size: 48)
            : SizedBox(
                width: 32,
                child: Center(
                  child: Text('${index != null ? index! + 1 : ''}',
                      style: TextStyle(color: playing ? AppColors.accent : cs.onSurfaceVariant)),
                ),
              ),
        if (selected)
          Container(
            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
            child: const Icon(Icons.check_circle, color: AppColors.accent, size: 28),
          ),
      ]),
      title: Text(track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: playing ? AppColors.accent : cs.onSurface, fontWeight: FontWeight.w500)),
      subtitle: Row(children: [
        if (track.source == TrackSource.download)
          const Padding(
            padding: EdgeInsets.only(right: 4),
            child: Icon(Icons.arrow_circle_down, size: 14, color: AppColors.accent),
          ),
        Expanded(
          child: Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurfaceVariant)),
        ),
      ]),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (trailing != null) trailing!,
        if (track.duration != null && MediaQuery.sizeOf(context).width > 720)
          Text(formatDuration(track.duration), style: TextStyle(color: cs.onSurfaceVariant)),
        if (!selecting)
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () => showTrackMenu(context, ref, track, onRemove: onRemove, removeLabel: removeLabel),
          ),
        if (dragHandle != null && !selecting) dragHandle!,
      ]),
    );
    // Right-click starts selecting on desktop.
    return selection == null ? tile : GestureDetector(onSecondaryTap: select, child: tile);
  }
}

/// A missing song's menu: find it on YouTube Music, or take it out of the list.
Future<void> showMissingSongMenu(BuildContext context, WidgetRef ref, Track track, {VoidCallback? onRemove, String removeLabel = '移除'}) =>
    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.music_off_outlined),
            title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${track.artist} • 手機上還沒有這首歌，有了之後會自動補上'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.library_music_outlined),
            title: const Text('從音樂庫選擇這首歌'),
            subtitle: const Text('手機上其實有，只是沒自動對上時用'),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => PickReplacementPage(missing: track)));
            },
          ),
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('取得 YouTube Music 連結'),
            subtitle: const Text('在「缺少的歌曲」頁面查詢'),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => const MissingSongsPage()));
            },
          ),
          if (onRemove != null)
            ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: Text(removeLabel),
              onTap: () async {
                Navigator.pop(ctx);
                if (await confirmDelete(context, title: '$removeLabel？', message: '${track.title}（缺少的歌曲）')) onRemove();
              },
            ),
        ]),
      ),
    );

Future<void> showTrackMenu(BuildContext context, WidgetRef ref, Track track, {VoidCallback? onRemove, String removeLabel = '移除'}) async {
  final handler = ref.read(audioHandlerProvider);
  final db = ref.read(dbProvider);
  final favs = ref.read(favoriteIdsProvider).value ?? {};
  final isFav = favs.contains(track.id);
  await showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: ArtImage(track.art, size: 48),
            title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(track.artist, maxLines: 1),
          ),
          const Divider(),
          ListTile(
            leading: Icon(isFav ? Icons.favorite : Icons.favorite_border, color: isFav ? AppColors.accent : null),
            title: Text(isFav ? '從已按讚的歌曲移除' : '加到已按讚的歌曲'),
            onTap: () {
              Navigator.pop(ctx);
              db.setFavorite(track, !isFav);
            },
          ),
          ListTile(
            leading: const Icon(Icons.playlist_add),
            title: const Text('加入播放清單'),
            onTap: () {
              Navigator.pop(ctx);
              showAddToPlaylist(context, ref, [track]);
            },
          ),
          ListTile(
            leading: const Icon(Icons.queue_play_next),
            title: const Text('下一首播放'),
            onTap: () {
              Navigator.pop(ctx);
              handler.playNext(track);
            },
          ),
          ListTile(
            leading: const Icon(Icons.queue_music),
            title: const Text('加入佇列'),
            onTap: () {
              Navigator.pop(ctx);
              handler.enqueue([track]);
            },
          ),
          if (track.source != TrackSource.url && track.source != TrackSource.podcast) ...[
            ListTile(
              leading: const Icon(Icons.album),
              title: const Text('前往專輯'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => CollectionPage.album(track.album)));
              },
            ),
            ListTile(
              leading: const Icon(Icons.person),
              title: const Text('前往演出者'),
              onTap: () {
                Navigator.pop(ctx);
                openArtist(context, track);
              },
            ),
          ],
          if (isLocalFile(track))
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('在資料夾中顯示'),
              subtitle: Text(Platform.isWindows ? '用檔案總管開啟並選取這首歌' : '在「瀏覽資料夾」打開這首歌所在的資料夾'),
              onTap: () {
                Navigator.pop(ctx);
                showInFolder(context, track);
              },
            ),
          if (onRemove != null)
            ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: Text(removeLabel),
              onTap: () async {
                Navigator.pop(ctx);
                if (await confirmDelete(context, title: '$removeLabel？', message: track.title)) onRemove();
              },
            ),
          if (track.source == TrackSource.local || track.source == TrackSource.download)
            ListTile(
              leading: const Icon(Icons.image_search_outlined),
              title: const Text('找正式封面'),
              subtitle: const Text('從 iTunes 找正方形的專輯封面'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => CoverFixPage(tracks: [track])));
              },
            ),
          if (NativeNames.wants(track))
            ListTile(
              leading: const Icon(Icons.translate),
              title: const Text('找原文歌名'),
              subtitle: const Text('羅馬拼音或英文的歌名，查日文或中文的原名'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => NativeNamePage(tracks: [track])));
              },
            ),
          if (track.source == TrackSource.local || track.source == TrackSource.download)
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('編輯資訊'),
              subtitle: const Text('歌名、歌手、專輯、封面'),
              onTap: () {
                Navigator.pop(ctx);
                showEditTrack(context, ref, track);
              },
            ),
          if (track.source == TrackSource.local || track.source == TrackSource.download)
            ListTile(
              leading: const Icon(Icons.hide_source),
              title: const Text('從音樂庫隱藏'),
              subtitle: const Text('不會刪除檔案；重新掃描後會再出現'),
              onTap: () async {
                Navigator.pop(ctx);
                final where = await removalLines(ref, [track]);
                if (!context.mounted) return;
                if (await confirmDelete(context,
                    title: '從音樂庫隱藏「${track.title}」？',
                    message: '檔案不會被刪除，重新掃描後會再出現在音樂庫。會從以下地方移除：\n${where.map((l) => '• $l').join('\n')}',
                    action: '隱藏')) {
                  await db.deleteTracks([track.id]);
                }
              },
            ),
          if (track.source == TrackSource.local || track.source == TrackSource.download)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: Text(ref.read(settingsProvider).deletePermanently ? '永久刪除檔案' : '刪除檔案', style: const TextStyle(color: Colors.redAccent)),
              subtitle: Text(ref.read(settingsProvider).deletePermanently ? '無法還原' : '移到$trashName，可以還原'),
              onTap: () {
                Navigator.pop(ctx);
                deleteTrackFiles(context, ref, [track]);
              },
            ),
        ]),
      ),
    ),
  );
}

/// Where removing [tracks] takes them out of (see [describeRemoval]).
Future<List<String>> removalLines(WidgetRef ref, List<Track> tracks) async {
  final impact = await ref.read(dbProvider).removalImpact(tracks.map((t) => t.id).toList());
  final ids = {for (final t in tracks) t.id};
  final inQueue = ref.read(audioHandlerProvider).tracks.where((t) => ids.contains(t.id)).length;
  return describeRemoval(impact, songs: tracks.length, inQueue: inQueue);
}

/// Asks first (listing everywhere the songs will be removed from), moves the
/// files to the trash — or deletes them for good if 永久刪除 is on — then
/// removes the songs from the library, playlists, likes and the queue.
/// Returns true if they were deleted.
Future<bool> deleteTrackFiles(BuildContext context, WidgetRef ref, List<Track> tracks, {String? title}) async {
  if (tracks.isEmpty) return false;
  final forever = ref.read(settingsProvider).deletePermanently;
  final where = await removalLines(ref, tracks);
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => AlertDialog(
      title: Text(title ?? '${forever ? '永久刪除' : '刪除'}${tracks.length == 1 ? '檔案' : ' ${tracks.length} 個檔案'}？'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final t in tracks.take(5)) Text(p.basename(t.uri), style: const TextStyle(fontWeight: FontWeight.bold)),
          if (tracks.length > 5) Text('…以及其他 ${tracks.length - 5} 個'),
          const SizedBox(height: 8),
          forever
              ? const Text('檔案會永久刪除，無法還原。', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold))
              : Text('檔案會移到$trashName，可以還原。'),
          const SizedBox(height: 4),
          const Text('並從以下地方移除：'),
          RemovalList(where),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(forever ? '永久刪除' : '刪除'),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  try {
    final paths = tracks.map((t) => t.uri).toList();
    if (!await (forever ? deleteForever(paths) : moveToTrash(paths))) {
      if (context.mounted) toast(context, '已取消刪除');
      return false;
    }
    final handler = ref.read(audioHandlerProvider);
    for (final t in tracks) {
      await handler.removeTrack(t.id);
    }
    await ref.read(dbProvider).deleteTracks(tracks.map((t) => t.id));
    if (context.mounted) toast(context, forever ? '已永久刪除' : '已移到$trashName');
    return true;
  } catch (e) {
    if (context.mounted) toast(context, '刪除失敗：$e');
    return false;
  }
}
