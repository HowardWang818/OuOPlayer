
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../providers/sync_provider.dart';
import '../../services/file_trash.dart';
import '../../theme/app_theme.dart';
import '../../theme/looks.dart';
import '../pages/pick_replacement_page.dart';
import 'art_image.dart';
import 'dialogs.dart';
import 'missing_download.dart';
import 'removal_summary.dart';
import 'song_actions.dart';
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
    // 外觀 → 清單密度.
    final compact = Looks.of(context).compact;
    final art = compact ? 38.0 : 48.0;
    final density = compact ? const VisualDensity(vertical: -3) : null;
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
        selectedTileColor: AppTheme.accent(context).withValues(alpha: 0.15),
        onTap: selecting ? select : () => showMissingSongMenu(context, ref, track, onRemove: onRemove, removeLabel: removeLabel),
        onLongPress: selection == null ? null : select,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        dense: compact,
        visualDensity: density,
        leading: Opacity(
          opacity: 0.4,
          child: showArt
              ? SizedBox(width: art, height: art, child: const Icon(Icons.music_off_outlined))
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
      selectedTileColor: AppTheme.accent(context).withValues(alpha: 0.15),
      // While selecting, a tap (or Ctrl/Shift+click on desktop) toggles the row.
      onTap: selection != null &&
              (selecting || HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isShiftPressed)
          ? select
          : onTap,
      onLongPress: selection == null ? null : select,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      dense: compact,
      visualDensity: density,
      // Selected rows keep their cover (or track number) with a solid check on top.
      leading: Stack(alignment: Alignment.center, children: [
        showArt
            ? ArtImage(track.art, size: art)
            : SizedBox(
                width: 32,
                child: Center(
                  child: Text('${index != null ? index! + 1 : ''}',
                      style: TextStyle(color: playing ? AppTheme.accent(context) : cs.onSurfaceVariant)),
                ),
              ),
        if (selected)
          Container(
            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
            child: Icon(Icons.check_circle, color: AppTheme.accent(context), size: 28),
          ),
      ]),
      title: Text(track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: playing ? AppTheme.accent(context) : cs.onSurface, fontWeight: FontWeight.w500)),
      subtitle: Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurfaceVariant)),
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

/// A missing song's menu: download it, pick it from the library, or take it
/// out of the list.
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
            subtitle: Text('${track.artist} • 缺少'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.library_music_outlined),
            title: const Text('從音樂庫選擇'),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => PickReplacementPage(missing: track)));
            },
          ),
          ListTile(
            leading: const Icon(Icons.download_rounded),
            title: const Text('下載'),
            onTap: () {
              Navigator.pop(ctx);
              downloadMissingSong(context, track);
            },
          ),
          if (syncAvailable && ref.read(syncProvider).signedIn)
            ListTile(
              leading: const Icon(Icons.cloud_sync_outlined),
              title: const Text('重新傳送'),
              onTap: () async {
                Navigator.pop(ctx);
                await resendSongs(context, ref, [track]);
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

/// The song menu for one song: the same entries as for selected songs.
Future<void> showTrackMenu(BuildContext context, WidgetRef ref, Track track, {VoidCallback? onRemove, String removeLabel = '移除'}) =>
    showSongMenu(context, ref, track, onRemove: onRemove == null ? null : () async => onRemove(), removeLabel: removeLabel);

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
          const Text('並從以下地方移除，同步的播放清單在另一台也會移除：'),
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
    final db = ref.read(dbProvider);
    // Out of the playlists and likes here and on synced devices, then gone.
    await db.takeOutOfLists(tracks.map((t) => t.id));
    await db.deleteTracks(tracks.map((t) => t.id));
    if (context.mounted) toast(context, forever ? '已永久刪除' : '已移到$trashName');
    return true;
  } catch (e) {
    if (context.mounted) toast(context, '刪除失敗：$e');
    return false;
  }
}
