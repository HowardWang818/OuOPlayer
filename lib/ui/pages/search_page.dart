import 'dart:async';

import 'package:flutter/material.dart';

import 'podcast_search_page.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/network_check.dart';
import '../../services/download_service.dart';
import '../../services/online/ytmusic.dart';
import '../widgets/art_image.dart';
import '../widgets/dialogs.dart';
import '../widgets/track_selection.dart';
import '../widgets/track_tile.dart';
import '../widgets/empty_state.dart';
import '../widgets/download_actions.dart';

/// The search shortcut: the search box takes the cursor once the page is there.
final searchFocusWanted = ValueNotifier(false);

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  // Restored from searchStateProvider so the query survives tab switches.
  late final _ctrl = TextEditingController(text: ref.read(searchStateProvider).text);

  SearchStateNotifier get _search => ref.read(searchStateProvider.notifier);

  /// The library search follows typing after a short pause, not per key.
  Timer? _debounce;
  late String _libraryQuery = ref.read(searchStateProvider).text;

  void _onTyped(String v) {
    _search.setText(v.trim());
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _libraryQuery = v.trim());
    });
  }

  final _box = FocusNode();

  void _takeFocus() {
    if (!searchFocusWanted.value) return;
    searchFocusWanted.value = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _box.requestFocus();
    });
  }

  @override
  void initState() {
    super.initState();
    searchFocusWanted.addListener(_takeFocus);
    _takeFocus();
  }

  @override
  void dispose() {
    searchFocusWanted.removeListener(_takeFocus);
    _box.dispose();
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  /// Online searches run on submit (not per keystroke) to spare the API.
  void _submit() {
    final s = ref.read(searchStateProvider);
    if (s.online) _search.setOnlineQuery(s.text);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(searchStateProvider);
    final q = s.text;
    final online = s.online;
    final onlineQuery = s.onlineQuery;
    final isUrl = q.startsWith('http://') || q.startsWith('https://');
    return Scaffold(
      appBar: AppBar(title: const Text('搜尋')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            controller: _ctrl,
            focusNode: _box,
            textInputAction: TextInputAction.search,
            onChanged: _onTyped,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: s.podcast
                  ? '搜尋 Podcast 節目或主持人（按搜尋鍵查詢）'
                  : online
                      ? '搜尋歌曲（按搜尋鍵查詢）'
                      : '想聽什麼？（或貼上音樂 / 串流網址）',
              suffixIcon: q.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _ctrl.clear();
                        _search.clear();
                      },
                    ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(children: [
            for (final (tabOnline, tabPodcast, label) in [(false, false, '音樂庫'), (true, false, '網路'), (true, true, 'Podcast')])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(label),
                  selected: online == tabOnline && s.podcast == tabPodcast,
                  showCheckmark: false,
                  labelStyle: TextStyle(color: online == tabOnline && s.podcast == tabPodcast ? Colors.black : null),
                  onSelected: (_) {
                    _search.setOnline(tabOnline, podcast: tabPodcast);
                    if (tabOnline && q.isNotEmpty && !isUrl) _search.setOnlineQuery(q);
                  },
                ),
              ),
          ]),
        ),
        Expanded(
          child: isUrl
              ? _UrlActions(url: q)
              : s.podcast
                  ? PodcastSearchResults(query: onlineQuery, pending: q.isNotEmpty && q != onlineQuery, onSearch: _submit)
                  : online
                  ? _OnlineResults(query: onlineQuery, pending: q.isNotEmpty && q != onlineQuery, onSearch: _submit)
                  : q.isEmpty
                      ? const EmptyState(icon: Icons.search_rounded, title: '搜尋歌曲、演出者或專輯')
                      : _LibraryResults(query: _libraryQuery.isEmpty ? q : _libraryQuery),
        ),
      ]),
    );
  }
}

class _LibraryResults extends ConsumerWidget {
  const _LibraryResults({required this.query});
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(searchProvider(query)).value ?? const <Track>[];
    final handler = ref.read(audioHandlerProvider);
    if (results.isEmpty) return EmptyState(icon: Icons.search_off_rounded, title: '找不到「$query」');
    return TrackSelectionScope(
      tracks: results,
      child: ListView.builder(
        itemCount: results.length,
        itemBuilder: (_, i) => TrackTile(track: results[i], selectIndex: i, onTap: () => handler.playTracks(results, index: i)),
      ),
    );
  }
}

class _UrlActions extends ConsumerWidget {
  const _UrlActions({required this.url});
  final String url;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final handler = ref.read(audioHandlerProvider);
    return ListView(children: [
      ListTile(
        leading: const Icon(Icons.play_circle_outline),
        title: const Text('串流播放此網址'),
        subtitle: Text(url, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () => handler.playTracks([Track.fromUrl(url)]),
      ),
      ListTile(
        leading: const Icon(Icons.download),
        title: const Text('下載到本機'),
        subtitle: const Text('直連檔案直接下載，其他網址交給 yt-dlp'),
        onTap: () async {
          if (await startDownload(context, url) && context.mounted) ref.read(tabProvider.notifier).set(3);
        },
      ),
      ListTile(
        leading: const Icon(Icons.file_download_outlined),
        title: const Text('以直接下載方式下載'),
        onTap: () async {
          if (!await acceptDownloadTerms(context) || !context.mounted) return;
          if (!await okToDownload(context, warn: ref.read(settingsProvider).wifiWarning) || !context.mounted) return;
          ref.read(downloadServiceProvider).add(url, kind: DownloadKind.direct);
          toast(context, '已加入下載佇列');
        },
      ),
    ]);
  }
}

/// YouTube Music songs: tap plays a preview, the button downloads.
class _OnlineResults extends ConsumerWidget {
  const _OnlineResults({required this.query, required this.pending, required this.onSearch});
  final String query;
  final bool pending;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (pending) {
      return Center(
        child: FilledButton.icon(onPressed: onSearch, icon: const Icon(Icons.travel_explore), label: const Text('搜尋')),
      );
    }
    if (query.isEmpty) {
      return const EmptyState(icon: Icons.travel_explore_rounded, title: '搜尋 YouTube Music');
    }
    final async = ref.watch(ytMusicSearchProvider(query));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState.error(e, onRetry: () => ref.invalidate(ytMusicSearchProvider(query))),
      data: (songs) => songs.isEmpty
          ? EmptyState(icon: Icons.search_off_rounded, title: '找不到「$query」')
          : ListView.builder(
              itemCount: songs.length,
              itemBuilder: (_, i) => _OnlineSongTile(song: songs[i]),
            ),
    );
  }
}

class _OnlineSongTile extends ConsumerStatefulWidget {
  const _OnlineSongTile({required this.song});
  final YtMusicSong song;

  @override
  ConsumerState<_OnlineSongTile> createState() => _OnlineSongTileState();
}

class _OnlineSongTileState extends ConsumerState<_OnlineSongTile> {
  bool _loading = false;

  Future<void> _preview() async {
    final song = widget.song;
    setState(() => _loading = true);
    try {
      final stream = await ref.read(downloadServiceProvider).streamUrl(song.url);
      if (!mounted) return;
      if (stream == null) {
        toast(context, '無法試聽');
        return;
      }
      previewSources[stream] = (url: song.url, title: song.title);
      await ref.read(audioHandlerProvider).playTracks([
        Track.fromUrl(stream, title: song.title, artist: song.artist, album: song.album ?? '', art: song.artwork, durationMs: song.durationMs, source: TrackSource.preview),
      ]);
    } catch (_) {
      if (mounted) toast(context, '無法試聽');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final info = [
      if (song.artist.isNotEmpty) song.artist,
      if (song.album != null) song.album!,
      if (song.durationMs != null) formatDuration(Duration(milliseconds: song.durationMs!)),
    ].join(' • ');
    return ListTile(
      leading: _loading
          ? const SizedBox(width: 48, height: 48, child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))))
          : ArtImage(song.artwork, size: 48),
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(info, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: muted)),
      trailing: IconButton(
        tooltip: '下載',
        icon: const Icon(Icons.download_rounded),
        onPressed: () => startDownload(context, song.url, title: song.title),
      ),
      onTap: _loading ? null : _preview,
    );
  }
}
