import 'dart:async';

import 'package:flutter/material.dart';

import 'podcast_search_page.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/network_check.dart';
import '../../services/download_service.dart';
import '../../services/online/preview_match.dart';
import '../../services/online/online_search.dart';
import '../../services/online/ytmusic.dart';
import '../widgets/art_image.dart';
import '../widgets/dialogs.dart';
import '../widgets/track_selection.dart';
import '../widgets/track_tile.dart';
import '../widgets/empty_state.dart';
import '../widgets/cover_progress.dart';
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
          child: Row(children: [
          Expanded(child: TextField(
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
          )),
          // 網路 only: the platform it searches, switchable.
          if (online && !s.podcast) ...[
            const SizedBox(width: 8),
            const _SourceButton(),
          ],
          ]),
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
                    if (tabOnline && !tabPodcast) firstOnlineVisit(context, ref);
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

/// 線上搜尋 results: tap plays a preview, the button downloads.
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
      return const EmptyState(icon: Icons.travel_explore_rounded, title: '線上搜尋');
    }
    final source = ref.watch(onlineSourceProvider);
    if (source == null) {
      return EmptyState(icon: Icons.travel_explore_rounded, title: '選擇搜尋平台', action: '選擇', onAction: () => pickOnlineSource(context, ref));
    }
    final key = (source, query);
    final async = ref.watch(onlineSongsProvider(key));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState.error(e, onRetry: () => ref.invalidate(onlineSongsProvider(key))),
      data: (songs) => songs.isEmpty
          ? EmptyState(icon: Icons.search_off_rounded, title: '找不到「$query」')
          : ListView.builder(
              itemCount: songs.length + 1,
              itemBuilder: (_, i) => i == 0 ? const _OnlineNote() : _OnlineSongTile(song: songs[i - 1]),
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
      // iTunes' 30-second preview of the same song (YouTube isn't streamed).
      final found = previewMatch(song.title, song.artist, await ref.read(iTunesSearchProvider).search('${song.title} ${song.artist}', limit: 15), durationMs: song.durationMs);
      final clip = found?.previewUrl;
      if (!mounted) return;
      if (clip == null) {
        toast(context, '無法試聽');
        return;
      }
      previewSources[clip] = (url: song.url, title: song.title);
      await ref.read(audioHandlerProvider).playTracks([
        Track.fromUrl(clip, title: '${song.title}（試聽）', artist: song.artist, album: song.album ?? '', art: song.artwork, durationMs: 30000, source: TrackSource.preview),
      ]);
      if (mounted) toast(context, '試聽 30 秒');
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
    ref.watch(downloadsProvider);
    final task = ref.read(downloadServiceProvider).taskFor(song.url);
    return ListTile(
      leading: _loading
          ? const SizedBox(width: 48, height: 48, child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))))
          : CoverProgress(art: song.artwork, task: task),
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(info, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: muted)),
      trailing: IconButton(
        tooltip: '下載',
        icon: const Icon(Icons.download_rounded),
        onPressed: () => startDownload(context, song.url, title: song.title, artist: song.artist, album: song.album, art: song.artwork),
      ),
      onTap: _loading ? null : _preview,
    );
  }
}

/// The fixed line above online results: a local player, songs are kept by
/// downloading them.
class _OnlineNote extends StatelessWidget {
  const _OnlineNote();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(children: [
        Icon(Icons.info_outline, size: 16, color: cs.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(child: Text(onlineNote, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))),
      ]),
    );
  }
}

const onlineNote = '下載後才能播放，試聽僅 30 秒';
const localPlayerTitle = 'OuOPlayer 是本機播放器';
const localPlayerText = '線上搜尋用於尋找並下載歌曲，下載後即可離線播放。';
const localPlayerKey = 'online_intro_seen';

/// 線上搜尋 the first time: OuOPlayer plays downloaded songs, not streams.
Future<void> explainLocalPlayer(BuildContext context, WidgetRef ref) async {
  final db = ref.read(dbProvider);
  if ((await db.allSettings())[localPlayerKey] == 'true' || !context.mounted) return;
  await db.setSetting(localPlayerKey, 'true');
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => AlertDialog(
      title: const Text(localPlayerTitle),
      content: const Text(localPlayerText),
      actions: [FilledButton(autofocus: true, onPressed: () => Navigator.pop(ctx), child: const Text('好'))],
    ),
  );
}

/// The platform button at the right of the search box (網路 only).
class _SourceButton extends ConsumerWidget {
  const _SourceButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(onlineSourceProvider);
    return OutlinedButton(
      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12), minimumSize: const Size(0, 48)),
      onPressed: () => pickOnlineSource(context, ref),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(source?.label ?? '平台'),
        const Icon(Icons.arrow_drop_down),
      ]),
    );
  }
}

/// 選擇搜尋平台: the user's pick, remembered.
Future<void> pickOnlineSource(BuildContext context, WidgetRef ref) async {
  final current = ref.read(onlineSourceProvider);
  final picked = await showModalBottomSheet<OnlineSource>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const ListTile(title: Text('搜尋平台', style: TextStyle(fontWeight: FontWeight.w600))),
        for (final s in OnlineSource.values)
          ListTile(
            leading: Icon(s == current ? Icons.radio_button_checked : Icons.radio_button_unchecked),
            title: Text(s.label),
            onTap: () => Navigator.pop(ctx, s),
          ),
      ]),
    ),
  );
  if (picked != null) await ref.read(onlineSourceProvider.notifier).set(picked);
}

/// The first time 網路 opens: what OuOPlayer is, then which platform.
Future<void> firstOnlineVisit(BuildContext context, WidgetRef ref) async {
  await explainLocalPlayer(context, ref);
  final saved = (await ref.read(dbProvider).allSettings())[OnlineSource.key];
  if (saved == null && context.mounted) await pickOnlineSource(context, ref);
}
