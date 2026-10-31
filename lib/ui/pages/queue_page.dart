import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../theme/app_theme.dart';
import '../widgets/art_image.dart';
import '../widgets/dialogs.dart';
import '../widgets/song_font.dart';

class QueuePage extends StatelessWidget {
  const QueuePage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('佇列')), body: const QueueList());
}

/// The queue: drag to move, swipe to remove, tap to play. It starts at the
/// song playing: songs already played aren't shown, but stay in the queue, so
/// 上一首 still reaches them.
class QueueList extends ConsumerWidget {
  const QueueList({super.key});

  static const rowHeight = 64.0;

  /// Windows: the height that fills [height] with whole rows, so none is cut
  /// off at the bottom.
  static double wholeRows(double height) => height / max(1, (height / rowHeight).floor());

  /// How many songs at the head of a queue of [length] are already played.
  static int played(int? index, int length) => min(index ?? 0, max(0, length - 1));

  /// Scrolling stops on a whole row.
  static bool _snap(ScrollEndNotification n, double extent) {
    final at = n.metrics.pixels;
    final target = ((at / extent).round() * extent).clamp(0.0, n.metrics.maxScrollExtent);
    final position = n.context == null ? null : Scrollable.maybeOf(n.context!)?.position;
    if (position != null && (target - at).abs() > 0.5) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (position.hasPixels) position.animateTo(target, duration: const Duration(milliseconds: 120), curve: Curves.easeOut);
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!Platform.isWindows) return _list(context, ref, null);
    return LayoutBuilder(builder: (context, c) {
      final extent = wholeRows(c.maxHeight);
      return NotificationListener<ScrollEndNotification>(onNotification: (n) => _snap(n, extent), child: _list(context, ref, extent));
    });
  }

  Widget _list(BuildContext context, WidgetRef ref, double? extent) {
    final queue = ref.watch(queueProvider).value ?? const [];
    final index = ref.watch(playbackStateProvider).value?.queueIndex;
    final handler = ref.read(audioHandlerProvider);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final font = ref.watch(songFontProvider);
    final skip = played(index, queue.length);
    return queue.isEmpty
          ? const Center(child: Text('佇列是空的'))
          : ReorderableListView.builder(
              itemCount: queue.length - skip,
              itemExtent: extent,
              // Windows: the row's own handle instead of the one the list adds.
              buildDefaultDragHandles: !Platform.isWindows,
              onReorderItem: (from, to) {
                // The song playing stays at the top.
                if (from == 0) return;
                handler.moveQueueItem(from + skip, max(1, to) + skip);
              },
              itemBuilder: (context, row) {
                final i = row + skip;
                final t = Track.fromMediaItem(queue[i]);
                final current = i == index;
                return Dismissible(
                  key: ValueKey('${queue[i].id}#$i'),
                  direction: current ? DismissDirection.none : DismissDirection.endToStart,
                  background: Container(color: Colors.red.shade700, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 20), child: const Icon(Icons.delete)),
                  confirmDismiss: (_) => confirmDelete(context, title: '從佇列移除「${t.title}」？'),
                  onDismissed: (_) => handler.removeAt(i),
                  child: ListTile(
                    leading: ArtImage(t.art, size: 44),
                    title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: font.title(TextStyle(color: current ? AppTheme.accent(context) : null, fontWeight: current ? FontWeight.bold : null))),
                    subtitle: Text(handler.isQueuedAt(i) ? '插播 • ${t.artist}' : t.artist, maxLines: 1, style: font.artist(TextStyle(color: muted))),
                    trailing: Platform.isWindows
                        ? ReorderableDragStartListener(index: row, child: const Icon(Icons.menu))
                        : const Icon(Icons.menu),
                    onTap: () => handler.skipToQueueItem(i),
                  ),
                );
              },
            );
  }
}
