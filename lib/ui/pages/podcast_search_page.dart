import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/online/itunes.dart';
import '../widgets/art_image.dart';
import '../widgets/dialogs.dart';
import 'podcasts_page.dart';

/// 搜尋 Podcast: shows from Apple's directory by name or host.
class PodcastSearchPage extends ConsumerStatefulWidget {
  const PodcastSearchPage({super.key});

  @override
  ConsumerState<PodcastSearchPage> createState() => _PodcastSearchPageState();
}

class _PodcastSearchPageState extends ConsumerState<PodcastSearchPage> {
  final _ctrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() => setState(() => _query = _ctrl.text.trim());

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('搜尋 Podcast')),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _ctrl,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _submit(),
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: '節目名稱或主持人（按搜尋鍵查詢）'),
            ),
          ),
          Expanded(
            child: PodcastSearchResults(query: _query, pending: _ctrl.text.trim().isNotEmpty && _ctrl.text.trim() != _query, onSearch: _submit),
          ),
        ]),
      );
}

/// Results for [query] (searches run on submit to spare the API); tap to see
/// the episodes before subscribing, or subscribe right away.
class PodcastSearchResults extends ConsumerWidget {
  const PodcastSearchResults({super.key, required this.query, required this.pending, required this.onSearch});
  final String query;
  final bool pending;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    if (query.isEmpty) {
      return Center(
        child: pending
            ? FilledButton.icon(onPressed: onSearch, icon: const Icon(Icons.search), label: const Text('搜尋 Podcast'))
            : Text('從 Apple Podcast 目錄搜尋節目', style: TextStyle(color: muted)),
      );
    }
    final subscribed = {for (final p in ref.watch(podcastsProvider).value ?? const <Podcast>[]) p.feedUrl};
    return ref.watch(podcastSearchProvider(query)).when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text(e is DioException ? '無法連線，請檢查網路' : '搜尋失敗：$e')),
          data: (list) => list.isEmpty
              ? Center(child: Text('找不到「$query」相關的節目\n也可以用 RSS 網址訂閱', textAlign: TextAlign.center, style: TextStyle(color: muted)))
              : ListView(children: [
                  if (pending)
                    ListTile(leading: const Icon(Icons.search), title: const Text('按搜尋鍵查詢新的關鍵字'), onTap: onSearch),
                  for (final p in list) _PodcastResult(p, subscribed: subscribed.contains(p.feedUrl)),
                ]),
        );
  }
}

class _PodcastResult extends ConsumerWidget {
  const _PodcastResult(this.p, {required this.subscribed});
  final ITunesPodcast p;
  final bool subscribed;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListTile(
        leading: ArtImage(p.artwork, size: 56, icon: Icons.podcasts),
        title: Text(p.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [p.author, if (p.genre != null) p.genre!, if (p.episodes != null) '${p.episodes} 集'].join(' • '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PodcastEpisodesPage(podcast: p.toPodcast()))),
        trailing: subscribed
            ? const Chip(label: Text('已訂閱'))
            : IconButton(
                tooltip: '訂閱',
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () async {
                  await ref.read(dbProvider).savePodcast(p.toPodcast());
                  if (context.mounted) toast(context, '已訂閱「${p.title}」');
                },
              ),
      );
}
