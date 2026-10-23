import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/download_service.dart';
import '../../services/online/itunes.dart';
import '../widgets/art_image.dart';
import '../widgets/dialogs.dart';
import '../widgets/links.dart';
import '../widgets/track_tile.dart';
import 'youtube_key_guide_page.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  // Restored from searchStateProvider so the query survives tab switches.
  late final _ctrl = TextEditingController(text: ref.read(searchStateProvider).text);

  SearchStateNotifier get _search => ref.read(searchStateProvider.notifier);

  @override
  void dispose() {
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
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: const Text('搜尋')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            controller: _ctrl,
            textInputAction: TextInputAction.search,
            onChanged: (v) => _search.setText(v.trim()),
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: online ? '搜尋歌曲（按搜尋鍵查詢）' : '想聽什麼？（或貼上音樂 / 串流網址）',
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
            for (final (tabOnline, label) in [(false, '音樂庫'), (true, '網路')])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(label),
                  selected: online == tabOnline,
                  showCheckmark: false,
                  labelStyle: TextStyle(color: online == tabOnline ? Colors.black : null),
                  onSelected: (_) {
                    _search.setOnline(tabOnline);
                    if (tabOnline && q.isNotEmpty && !isUrl) _search.setOnlineQuery(q);
                  },
                ),
              ),
          ]),
        ),
        Expanded(
          child: isUrl
              ? _UrlActions(url: q)
              : online
                  ? _OnlineResults(query: onlineQuery, pending: q.isNotEmpty && q != onlineQuery, onSearch: _submit)
                  : q.isEmpty
                      ? Center(child: Text('搜尋歌曲、演出者或專輯', style: TextStyle(color: muted)))
                      : _LibraryResults(query: q),
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
    if (results.isEmpty) return const Center(child: Text('找不到結果'));
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (_, i) => TrackTile(track: results[i], onTap: () => handler.playTracks(results, index: i)),
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
        onTap: () {
          ref.read(downloadServiceProvider).add(url, format: ref.read(settingsProvider).ytFormat);
          toast(context, '已加入下載佇列');
          ref.read(tabProvider.notifier).set(3);
        },
      ),
      ListTile(
        leading: const Icon(Icons.file_download_outlined),
        title: const Text('以直接下載方式下載'),
        onTap: () {
          ref.read(downloadServiceProvider).add(url, kind: DownloadKind.direct);
          toast(context, '已加入下載佇列');
        },
      ),
    ]);
  }
}

/// iTunes results: tap plays the 30-second preview, ⋮ opens link actions.
class _OnlineResults extends ConsumerWidget {
  const _OnlineResults({required this.query, required this.pending, required this.onSearch});
  final String query;
  final bool pending;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    if (pending) {
      return Center(
        child: FilledButton.icon(onPressed: onSearch, icon: const Icon(Icons.travel_explore), label: const Text('在網路上搜尋')),
      );
    }
    if (query.isEmpty) {
      return Center(child: Text('搜尋 iTunes 曲庫，可試聽 30 秒', style: TextStyle(color: muted)));
    }
    final async = ref.watch(onlineSearchProvider(query));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off, size: 40),
            const SizedBox(height: 8),
            const Text('無法連線到 iTunes，請檢查網路'),
            TextButton(onPressed: () => ref.invalidate(onlineSearchProvider(query)), child: const Text('重試')),
          ]),
        ),
      ),
      data: (songs) => songs.isEmpty
          ? const Center(child: Text('找不到結果'))
          : ListView.builder(
              itemCount: songs.length + 2,
              itemBuilder: (_, i) => i == 0
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: Text('共 ${songs.length} 首', style: TextStyle(fontSize: 12, color: muted)),
                    )
                  : i == songs.length + 1
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('資料來源：iTunes Search API', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: muted)),
                    )
                  : _OnlineSongTile(song: songs[i - 1]),
            ),
    );
  }
}

class _OnlineSongTile extends ConsumerWidget {
  const _OnlineSongTile({required this.song});
  final ITunesSong song;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final preview = song.previewTrack;
    final duration = song.durationMs == null ? '' : ' • ${formatDuration(Duration(milliseconds: song.durationMs!))}';
    return ListTile(
      leading: ArtImage(song.artwork, size: 48),
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${song.artist} • ${song.album}$duration', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: muted)),
      trailing: IconButton(icon: const Icon(Icons.more_vert), onPressed: () => _showMenu(context, ref, song)),
      onTap: preview == null
          ? () => toast(context, '這首歌沒有提供試聽')
          : () {
              ref.read(audioHandlerProvider).playTracks([preview]);
              toast(context, '試聽 30 秒');
            },
    );
  }
}

Future<void> _showMenu(BuildContext context, WidgetRef ref, ITunesSong song) {
  return showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (ctx) {
      void act(VoidCallback f) {
        Navigator.pop(ctx);
        f();
      }

      return SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: ArtImage(song.artwork, size: 48),
              title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(song.artist, maxLines: 1),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('取得 YouTube 連結'),
              onTap: () => act(() => _getYouTubeLink(context, ref, song)),
            ),
            ListTile(
              leading: const Icon(Icons.music_note_outlined),
              title: const Text('在 Apple Music 開啟'),
              onTap: () => act(() => openExternal(context, song.appleMusicUrl)),
            ),
            ListTile(
              leading: const Icon(Icons.hub_outlined),
              title: const Text('所有平台（song.link）'),
              subtitle: const Text('Spotify、YouTube Music、KKBOX…'),
              onTap: () => act(() => openExternal(context, song.songLinkUrl)),
            ),
            ListTile(
              leading: const Icon(Icons.shopping_bag_outlined),
              title: const Text('在 mora 搜尋購買'),
              onTap: () => act(() => openExternal(context, song.moraUrl)),
            ),
            ListTile(
              leading: const Icon(Icons.shopping_bag_outlined),
              title: const Text('在 OTOTOY 搜尋購買'),
              onTap: () => act(() => openExternal(context, song.ototoyUrl)),
            ),
            ListTile(
              leading: const Icon(Icons.shopping_bag_outlined),
              title: const Text('在 iTunes Store 購買'),
              onTap: () => act(() => openExternal(context, song.iTunesStoreUrl)),
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('複製「歌名 - 歌手」'),
              onTap: () => act(() {
                Clipboard.setData(ClipboardData(text: '${song.title} - ${song.artist}'));
                toast(context, '已複製');
              }),
            ),
          ]),
        ),
      );
    },
  );
}

/// Looks up the song's YouTube video and shows + copies the link. Never opens it.
Future<void> _getYouTubeLink(BuildContext context, WidgetRef ref, ITunesSong song) async {
  final key = ref.read(settingsProvider).youtubeApiKey;
  if (key.isEmpty) {
    await showDialog(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        title: const Text('需要 YouTube 金鑰'),
        content: const Text('「取得 YouTube 連結」需要一組免費的 YouTube Data API 金鑰，申請約 5 分鐘。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => const YouTubeKeyGuidePage()));
            },
            child: const Text('查看申請步驟'),
          ),
        ],
      ),
    );
    return;
  }

  showDialog(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );
  String? error;
  String? url;
  String? detail;
  try {
    final video = await ref.read(youTubeLinkFinderProvider).find(key, song.query);
    if (video == null) {
      error = '找不到對應的影片';
    } else {
      url = video.url;
      detail = '${video.title}\n${video.channel}';
      await Clipboard.setData(ClipboardData(text: url));
    }
  } catch (e) {
    error = e.toString();
  }
  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop();
  await showDialog(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => AlertDialog(
      title: Text(error == null ? '已複製 YouTube 連結' : '無法取得連結'),
      content: error != null
          ? Text(error)
          : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              SelectableText(url!, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(detail!, style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 8),
              Text('自動比對的第一個結果，偶爾會是 MV、現場版或翻唱。', style: TextStyle(fontSize: 12, color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
            ]),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('好'))],
    ),
  );
}
