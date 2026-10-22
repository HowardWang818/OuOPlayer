import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../theme/app_theme.dart';
import '../widgets/art_image.dart';

class QueuePage extends ConsumerWidget {
  const QueuePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(queueProvider).value ?? const [];
    final index = ref.watch(playbackStateProvider).value?.queueIndex;
    final handler = ref.read(audioHandlerProvider);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: const Text('佇列')),
      body: queue.isEmpty
          ? const Center(child: Text('佇列是空的'))
          : ReorderableListView.builder(
              itemCount: queue.length,
              onReorderItem: (from, to) => handler.moveQueueItem(from, to),
              itemBuilder: (context, i) {
                final t = Track.fromMediaItem(queue[i]);
                final current = i == index;
                return Dismissible(
                  key: ValueKey('${queue[i].id}#$i'),
                  direction: current ? DismissDirection.none : DismissDirection.endToStart,
                  background: Container(color: Colors.red.shade700, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 20), child: const Icon(Icons.delete)),
                  onDismissed: (_) => handler.removeAt(i),
                  child: ListTile(
                    leading: ArtImage(t.art, size: 44),
                    title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: current ? AppColors.accent : null, fontWeight: current ? FontWeight.bold : null)),
                    subtitle: Text(t.artist, maxLines: 1, style: TextStyle(color: muted)),
                    trailing: const Icon(Icons.drag_handle),
                    onTap: () => handler.skipToQueueItem(i),
                  ),
                );
              },
            ),
    );
  }
}
