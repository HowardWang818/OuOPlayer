import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../theme/app_theme.dart';
import '../pages/collection_page.dart';
import 'art_image.dart';
import 'dialogs.dart';

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
  });

  final Track track;
  final VoidCallback onTap;
  final int? index;
  final bool showArt;
  final VoidCallback? onRemove;
  final String removeLabel;
  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(currentTrackProvider);
    final playing = current?.uri == track.uri;
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: showArt
          ? ArtImage(track.art, size: 48)
          : SizedBox(
              width: 32,
              child: Center(
                child: Text('${index != null ? index! + 1 : ''}',
                    style: TextStyle(color: playing ? AppColors.accent : cs.onSurfaceVariant)),
              ),
            ),
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
        IconButton(
          icon: const Icon(Icons.more_vert),
          onPressed: () => showTrackMenu(context, ref, track, onRemove: onRemove, removeLabel: removeLabel),
        ),
      ]),
    );
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
              onTap: () {
                Navigator.pop(ctx);
                onRemove();
              },
            ),
          if (track.source == TrackSource.local || track.source == TrackSource.download)
            ListTile(
              leading: const Icon(Icons.hide_source),
              title: const Text('從音樂庫隱藏'),
              subtitle: const Text('不會刪除檔案；重新掃描後會再出現'),
              onTap: () {
                Navigator.pop(ctx);
                db.deleteTracks([track.id]);
              },
            ),
        ]),
      ),
    ),
  );
}
