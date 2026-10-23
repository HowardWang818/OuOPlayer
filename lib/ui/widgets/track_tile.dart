import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/file_trash.dart';
import '../../theme/app_theme.dart';
import '../pages/collection_page.dart';
import 'art_image.dart';
import 'dialogs.dart';
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
    this.selectIndex,
  });

  final Track track;
  final VoidCallback onTap;
  final int? index;
  final bool showArt;
  final VoidCallback? onRemove;
  final String removeLabel;
  final Widget? trailing;

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
      ]),
    );
    // Right-click starts selecting on desktop.
    return selection == null ? tile : GestureDetector(onSecondaryTap: select, child: tile);
  }
}

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
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => CollectionPage.artist(track.artist)));
              },
            ),
          ],
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
              leading: const Icon(Icons.hide_source),
              title: const Text('從音樂庫隱藏'),
              subtitle: const Text('不會刪除檔案；重新掃描後會再出現'),
              onTap: () async {
                Navigator.pop(ctx);
                if (await confirmDelete(context,
                    title: '從音樂庫隱藏「${track.title}」？',
                    message: '檔案不會被刪除，但會從播放清單和已按讚的歌曲中移除；重新掃描後會再出現在音樂庫。',
                    action: '隱藏')) {
                  await db.deleteTracks([track.id]);
                }
              },
            ),
          if (track.source == TrackSource.local || track.source == TrackSource.download)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text('刪除檔案', style: TextStyle(color: Colors.redAccent)),
              subtitle: Text('移到$trashName，可以還原'),
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

/// Asks first, moves the files to the trash (one system prompt on Android),
/// then removes the songs from the library, playlists, likes and the queue.
/// Returns true if they were deleted.
Future<bool> deleteTrackFiles(BuildContext context, WidgetRef ref, List<Track> tracks) async {
  if (tracks.isEmpty) return false;
  final ok = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => AlertDialog(
      title: Text(tracks.length == 1 ? '刪除檔案？' : '刪除 ${tracks.length} 個檔案？'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final t in tracks.take(5)) Text(p.basename(t.uri), style: const TextStyle(fontWeight: FontWeight.bold)),
        if (tracks.length > 5) Text('…以及其他 ${tracks.length - 5} 個'),
        const SizedBox(height: 8),
        Text('檔案會移到$trashName，並從音樂庫、播放清單和已按讚的歌曲中移除。'),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('刪除'),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  try {
    if (!await moveToTrash(tracks.map((t) => t.uri).toList())) {
      if (context.mounted) toast(context, '已取消刪除');
      return false;
    }
    final handler = ref.read(audioHandlerProvider);
    for (final t in tracks) {
      await handler.removeTrack(t.id);
    }
    await ref.read(dbProvider).deleteTracks(tracks.map((t) => t.id));
    if (context.mounted) toast(context, '已移到$trashName');
    return true;
  } catch (e) {
    if (context.mounted) toast(context, '刪除失敗：$e');
    return false;
  }
}
