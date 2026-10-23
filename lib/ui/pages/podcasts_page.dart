import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/network_check.dart';
import '../../services/download_service.dart';
import '../../theme/app_theme.dart';
import '../widgets/art_image.dart';
import '../widgets/dialogs.dart';

Future<void> subscribePodcast(BuildContext context, WidgetRef ref) async {
  final url = await promptText(context, title: '訂閱 Podcast', hint: '貼上 RSS 網址', ok: '訂閱');
  if (url == null || url.isEmpty) return;
  try {
    final feed = await ref.read(podcastServiceProvider).fetch(url);
    await ref.read(dbProvider).savePodcast(feed.podcast);
    if (context.mounted) toast(context, '已訂閱「${feed.podcast.title}」');
  } catch (e) {
    if (context.mounted) toast(context, '無法讀取 RSS：$e');
  }
}

class PodcastsPage extends ConsumerWidget {
  const PodcastsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        appBar: AppBar(title: const Text('Podcast'), actions: [
          IconButton(icon: const Icon(Icons.add), tooltip: '訂閱', onPressed: () => subscribePodcast(context, ref)),
        ]),
        body: const PodcastList(),
      );
}

class PodcastList extends ConsumerWidget {
  const PodcastList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(podcastsProvider).value ?? const [];
    return ListView(children: [
      ListTile(
        leading: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), color: Theme.of(context).colorScheme.surfaceContainerHigh),
          child: const Icon(Icons.add),
        ),
        title: const Text('以 RSS 網址訂閱 Podcast'),
        onTap: () => subscribePodcast(context, ref),
      ),
      for (final p in list)
        ListTile(
          leading: ArtImage(p.image, size: 56, icon: Icons.podcasts),
          title: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('Podcast • ${p.author}', maxLines: 1),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PodcastEpisodesPage(podcast: p))),
        ),
    ]);
  }
}

class PodcastEpisodesPage extends ConsumerWidget {
  const PodcastEpisodesPage({super.key, required this.podcast});
  final Podcast podcast;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(podcastFeedProvider(podcast.feedUrl));
    final handler = ref.read(audioHandlerProvider);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final progress = ref.watch(podcastProgressProvider).value ?? const {};
    String? state(Track e) {
      final s = progress[e.uri];
      if (s == null) return null;
      if (s.finished) return '已聽完';
      final total = s.duration ?? e.duration;
      if (total == null) return '聽到 ${formatDuration(s.position)}';
      final left = total - s.position;
      return '剩 ${(left.inSeconds / 60).ceil()} 分鐘';
    }

    return Scaffold(
      appBar: AppBar(title: Text(podcast.title), actions: [
        PopupMenuButton<String>(
          onSelected: (v) async {
            if (v == 'unsub') {
              if (!await confirmDelete(context, title: '取消訂閱「${podcast.title}」？', action: '取消訂閱')) return;
              await ref.read(dbProvider).deletePodcast(podcast.feedUrl);
              if (context.mounted) Navigator.pop(context);
            } else {
              ref.invalidate(podcastFeedProvider(podcast.feedUrl));
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'refresh', child: Text('重新整理')),
            PopupMenuItem(value: 'unsub', child: Text('取消訂閱')),
          ],
        ),
      ]),
      body: feed.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('讀取失敗：$e')),
        data: (f) => ListView(children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              ArtImage(f.podcast.image, size: 120, radius: 8, icon: Icons.podcasts),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(f.podcast.title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                  Text(f.podcast.author, style: TextStyle(color: muted)),
                  const SizedBox(height: 8),
                  Text('${f.episodes.length} 集', style: TextStyle(color: muted)),
                ]),
              ),
            ]),
          ),
          for (var i = 0; i < f.episodes.length; i++)
            ListTile(
              title: Text(f.episodes[i].title, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                [
                  state(f.episodes[i]),
                  f.descriptions[f.episodes[i].uri],
                  if (f.episodes[i].duration != null) formatDuration(f.episodes[i].duration),
                ]
                    .whereType<String>()
                    .join(' • '),
                style: TextStyle(color: muted),
              ),
              onTap: () => handler.playTracks(f.episodes, index: i),
              onLongPress: progress[f.episodes[i].uri] == null
                  ? null
                  : () async {
                      if (await confirmDelete(context,
                          title: '清除「${f.episodes[i].title}」的收聽進度？', message: '會變回未聽過，下次從頭開始播放。', action: '清除')) {
                        await ref.read(dbProvider).clearPodcastProgress(f.episodes[i].uri);
                      }
                    },
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  tooltip: '下載',
                  icon: const Icon(Icons.download_for_offline_outlined),
                  onPressed: () async {
                    if (!await okToDownload(context, warn: ref.read(settingsProvider).wifiWarning) || !context.mounted) return;
                    ref.read(downloadServiceProvider).add(f.episodes[i].uri, kind: DownloadKind.direct, title: f.episodes[i].title);
                    toast(context, '已加入下載佇列');
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.play_circle_fill, color: AppColors.accent, size: 32),
                  onPressed: () => handler.playTracks(f.episodes, index: i),
                ),
              ]),
            ),
        ]),
      ),
    );
  }
}
