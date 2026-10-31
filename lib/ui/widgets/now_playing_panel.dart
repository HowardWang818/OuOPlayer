import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/window_state.dart';
import '../pages/collection_page.dart';
import 'art_image.dart';
import 'hover.dart';
import 'lyrics_view.dart';
import 'mini_player.dart';
import 'player_controls.dart';
import 'song_font.dart';
import 'track_links.dart';

/// Windows: the blocks on the right of everything (settings too): the song
/// playing with its lyrics on top, the queue from the next song below, with a
/// divider between them to drag.
class NowPlayingPanel extends ConsumerWidget {
  const NowPlayingPanel({super.key, required this.push});

  /// Opens a page in the middle column.
  final void Function(Widget page) push;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    final cs = Theme.of(context).colorScheme;
    Widget block(Widget child) => Container(
          decoration: BoxDecoration(color: cs.surface, borderRadius: BorderRadius.circular(8)),
          child: child,
        );
    if (track == null) {
      return block(Center(child: Text('沒有播放中的歌曲', style: TextStyle(color: cs.onSurfaceVariant))));
    }
    final queue = ref.watch(queueProvider).value ?? const [];
    final index = ref.watch(playbackStateProvider).value?.queueIndex;
    final first = index == null ? null : index + 1;
    final nextAt = first != null && first < queue.length ? first : null;
    final layout = ref.watch(desktopLayoutProvider);
    final notifier = ref.read(desktopLayoutProvider.notifier);
    return LayoutBuilder(builder: (context, c) {
      final most = max(DesktopLayout.queueMin, c.maxHeight - DesktopLayout.songMin - DesktopLayout.gap);
      final height = layout.queue.clamp(DesktopLayout.queueMin, most);
      return Column(children: [
        Expanded(child: block(_Song(track: track, lyrics: layout.lyrics, push: push))),
        PanelDivider(
          vertical: true,
          reversed: true,
          value: height,
          onDrag: (at) => notifier.setQueue(at.clamp(DesktopLayout.queueMin, most)),
          onEnd: notifier.save,
        ),
        SizedBox(
          height: height,
          child: block(Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('接下來', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: cs.onSurfaceVariant)),
              const SizedBox(height: 4),
              Expanded(
                child: nextAt == null
                    ? Center(child: Text('後面沒有歌了', style: TextStyle(color: cs.onSurfaceVariant)))
                    // As many songs as fit, no scrolling: drag the divider for more.
                    : LayoutBuilder(
                        builder: (_, box) => ReorderableListView.builder(
                          padding: EdgeInsets.zero,
                          physics: const NeverScrollableScrollPhysics(),
                          buildDefaultDragHandles: false,
                          itemCount: min((box.maxHeight / _QueueRow.height).floor(), queue.length - nextAt),
                          onReorderItem: (from, to) => ref.read(audioHandlerProvider).moveQueueItem(nextAt + from, nextAt + to),
                          itemBuilder: (_, i) => _QueueRow(
                            key: ValueKey('${queue[nextAt + i].id}#${nextAt + i}'),
                            index: i,
                            track: Track.fromMediaItem(queue[nextAt + i]),
                            onTap: () => ref.read(audioHandlerProvider).skipToQueueItem(nextAt + i),
                          ),
                        ),
                      ),
              ),
            ]),
          )),
        ),
      ]);
    });
  }
}

/// The top block: cover, names, and the lyrics unless they're hidden.
class _Song extends ConsumerWidget {
  const _Song({required this.track, required this.lyrics, required this.push});
  final Track track;
  final bool lyrics;
  final void Function(Widget page) push;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final font = ref.watch(songFontProvider);
    final small = font.artist(TextStyle(fontSize: 13, color: cs.onSurfaceVariant));
    Widget artist(TextStyle style) =>
        LinkText(track.artist, onTap: hasPages(track) ? () => push(CollectionPage.artist(primaryArtist(track))) : null, style: style);
    Widget album(TextStyle style) => LinkText(track.album, onTap: hasPages(track) ? () => push(CollectionPage.album(track.album)) : null, style: style);
    return LayoutBuilder(builder: (context, c) {
      // Hidden lyrics leave the room to the cover (names below it take about 130).
      final size = max(0.0, min(c.maxWidth - 32, lyrics ? c.maxHeight * 0.45 : c.maxHeight - 160));
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          GestureDetector(
            onTap: () => openNowPlaying(context),
            child: MouseRegion(cursor: SystemMouseCursors.click, child: ArtImage(track.art, size: size, radius: 8)),
          ),
          const SizedBox(height: 12),
          Marquee(
            auto: true,
            child: Text(track.title, key: ValueKey(track.id), maxLines: 1, softWrap: false, style: font.title(const TextStyle(fontSize: 36, height: 1.25))),
          ),
          Row(children: [
            Expanded(
              child: Marquee(
                still: Row(children: [
                  Flexible(child: artist(small)),
                  Text(' · ', style: small),
                  Flexible(child: album(small)),
                ]),
                child: Row(mainAxisSize: MainAxisSize.min, children: [artist(small), Text(' · ', style: small), album(small)]),
              ),
            ),
            IconButton(
              tooltip: lyrics ? '隱藏歌詞' : '顯示歌詞',
              isSelected: lyrics,
              icon: const Icon(Icons.lyrics_outlined),
              selectedIcon: Icon(Icons.lyrics, color: cs.primary),
              onPressed: ref.read(desktopLayoutProvider.notifier).toggleLyrics,
            ),
            const FavoriteButton(),
          ]),
          if (lyrics) ...[
            const SizedBox(height: 8),
            Expanded(child: LyricsInk.on(cs.surface, child: const LyricsView(tools: false))),
          ],
        ]),
      );
    });
  }
}

/// A song in the queue block: a square cover, its title and artist, and the
/// handle that moves it.
class _QueueRow extends ConsumerWidget {
  const _QueueRow({super.key, required this.index, required this.track, required this.onTap});
  final int index;
  final Track track;
  final VoidCallback onTap;

  static const height = 64.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final font = ref.watch(songFontProvider);
    return InkWell(
      hoverColor: Colors.transparent,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox.square(dimension: 56, child: ArtImage(track.art, size: 56, radius: 4)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: font.title(const TextStyle(fontSize: 15))),
              Text(track.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: font.artist(TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant))),
            ]),
          ),
          ReorderableDragStartListener(index: index, child: const Icon(Icons.menu)),
        ]),
      ),
    );
  }
}
