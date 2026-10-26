import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../theme/app_theme.dart';
import '../../services/artist_images.dart';
import '../../services/artists.dart';
import '../widgets/art_image.dart';
import '../widgets/artist_edit.dart';
import '../widgets/dialogs.dart';
import '../widgets/export_sheet.dart';
import '../widgets/image_viewer.dart';
import '../widgets/sort_button.dart';
import '../../services/network_check.dart';
import '../../services/song_matcher.dart';
import '../../services/track_sort.dart';
import '../widgets/track_selection.dart';
import '../widgets/track_tile.dart';
import 'cover_fix_page.dart';
import 'folder_page.dart';
import 'lyrics_batch_page.dart';
import 'native_name_page.dart';
import 'pick_songs_page.dart';

enum CollectionKind { album, artist, playlist, favorites, allSongs, folder, smart }

/// The search text of a list page (null: search closed), per page.
class ListSearchNotifier extends Notifier<String?> {
  ListSearchNotifier(this.page);
  final String page;
  @override
  String? build() => null;
  void set(String? v) => state = v;
}

final listSearchProvider = NotifierProvider.autoDispose.family<ListSearchNotifier, String?, String>(ListSearchNotifier.new);

/// Album / artist / playlist / liked-songs page with a Spotify-like header.
class CollectionPage extends ConsumerWidget {
  const CollectionPage._(this.kind, {this.name = '', this.playlistId, this.folder, this.smart});

  factory CollectionPage.album(String album) => CollectionPage._(CollectionKind.album, name: album);
  factory CollectionPage.artist(String artist) => CollectionPage._(CollectionKind.artist, name: artist);
  factory CollectionPage.playlist(int id, String name) => CollectionPage._(CollectionKind.playlist, name: name, playlistId: id);
  factory CollectionPage.favorites() => const CollectionPage._(CollectionKind.favorites, name: '已按讚的歌曲');
  factory CollectionPage.allSongs() => const CollectionPage._(CollectionKind.allSongs, name: '所有歌曲');

  /// A music folder; [folder] null means all local music (Android's 「本地音樂」).
  factory CollectionPage.folder(String? folder, String name) => CollectionPage._(CollectionKind.folder, name: name, folder: folder);

  /// Read-only playlist built from play counts.
  factory CollectionPage.smart(SmartList list) => CollectionPage._(CollectionKind.smart, name: list.label, smart: list);

  final CollectionKind kind;
  final SmartList? smart;
  final String name;
  final int? playlistId;
  final String? folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracksAsync = switch (kind) {
      CollectionKind.album => ref.watch(albumTracksProvider(name)),
      CollectionKind.artist => ref.watch(artistTracksProvider(name)),
      CollectionKind.playlist => ref.watch(playlistTracksProvider(playlistId!)),
      CollectionKind.favorites => ref.watch(favoritesProvider),
      CollectionKind.allSongs => ref.watch(tracksProvider),
      CollectionKind.folder => ref.watch(folderTracksProvider(folder)),
      CollectionKind.smart => ref.watch(smartTracksProvider(smart!)),
    };
    final source = tracksAsync.value ?? const <Track>[];
    // Shown order; [order] maps each row back to its place in [source] so
    // removing from a playlist hits the right song.
    final sortScope = kind == CollectionKind.smart ? 'smart_${smart!.name}' : kind.name;
    final sort = TrackSort.decode(ref.watch(sortProvider(sortScope)));
    final order = sort.order(source);
    final tracks = [for (final i in order) source[i]];
    // Identifies this list for the shuffle button and the search box.
    final pageKey = '${kind.name}:${playlistId ?? folder ?? smart?.name ?? name}';
    final search = ref.watch(listSearchProvider(pageKey));
    final words = foldText(search ?? '').split(' ').where((w) => w.isNotEmpty).toList();
    // Rows shown (indexes into [tracks]); playing a found song still plays the whole list from it.
    final reorderable = kind == CollectionKind.playlist && sort.key == TrackSortKey.custom && !sort.descending && words.isEmpty;
    final rows = [
      for (var i = 0; i < tracks.length; i++)
        if (words.isEmpty || words.every(foldText('${tracks[i].title} ${tracks[i].artist} ${tracks[i].album}').contains)) i,
    ];
    final info = playlistId == null ? null : ref.watch(playlistInfoProvider(playlistId!)).value;
    // A custom playlist cover wins over the first song's cover.
    // An artist page shows the artist's photo when one was found.
    final photo = kind == CollectionKind.artist ? ref.watch(artistImageProvider(name)).value : null;
    final art = info?.cover ?? photo ?? tracks.where((t) => t.art != null).firstOrNull?.art;
    final color = ref.watch(artColorProvider(art)).value ?? AppColors.accent.withValues(alpha: 0.5);
    final theme = Theme.of(context);
    final handler = ref.read(audioHandlerProvider);
    final db = ref.read(dbProvider);

    final label = switch (kind) {
      CollectionKind.album => '專輯',
      CollectionKind.artist => '演出者',
      CollectionKind.playlist => '播放清單',
      CollectionKind.folder => folder == null ? '本機' : '資料夾',
      CollectionKind.smart => '智慧播放清單 • ${smart!.description}',
      _ => '播放清單',
    };
    final totalMs = tracks.fold<int>(0, (s, t) => s + (t.durationMs ?? 0));
    final subtitle = [
      if (kind == CollectionKind.album && tracks.isNotEmpty) tracks.first.artist,
      () {
        final missing = tracks.where((t) => t.source == TrackSource.missing).length;
        return missing == 0 ? '${tracks.length} 首歌曲' : '${tracks.length - missing} 首歌曲（缺 $missing 首）';
      }(),
      if (totalMs > 0) '約 ${(totalMs / 60000).round()} 分鐘',
    ].join(' • ');

    Future<void> Function(List<int>)? removeMany = switch (kind) {
      CollectionKind.playlist => (idx) => db.removeFromPlaylistAt(playlistId!, [for (final i in idx) order[i]]),
      CollectionKind.favorites => (idx) async {
          for (final i in idx) {
            await db.setFavorite(tracks[i], false);
          }
        },
      _ => null,
    };
    return Scaffold(
      body: TrackSelectionScope(
        tracks: tracks,
        onRemove: removeMany,
        removeLabel: kind == CollectionKind.favorites ? '從已按讚的歌曲移除' : '從此播放清單移除',
        child: CustomScrollView(slivers: [
        SliverAppBar(
          pinned: true,
          expandedHeight: 300,
          backgroundColor: Color.lerp(color, theme.scaffoldBackgroundColor, 0.3),
          // While searching, the box sits in the top bar, left of the search button.
          title: search == null
              ? null
              : TextField(
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: '在這份清單裡搜尋',
                    isDense: true,
                    filled: true,
                    fillColor: theme.colorScheme.surface.withValues(alpha: 0.85),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    suffixText: search.isEmpty ? null : '${rows.length} 首',
                  ),
                  onChanged: (v) => ref.read(listSearchProvider(pageKey).notifier).set(v),
                ),
          actions: [
            IconButton(
              tooltip: '搜尋這份清單',
              icon: Icon(search == null ? Icons.search : Icons.search_off),
              onPressed: () => ref.read(listSearchProvider(pageKey).notifier).set(search == null ? '' : null),
            ),
            if (kind == CollectionKind.artist && name != '未知演出者')
              PopupMenuButton<String>(
                onSelected: (v) => switch (v) {
                  'rename' => renameArtist(context, ref, name),
                  'restore' => restoreArtistName(context, ref, name),
                  'photo' => pickArtistPhoto(context, ref, name),
                  'deezer' => pickDeezerPhoto(context, ref, name),
                  _ => removeArtistPhoto(context, ref, name),
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'rename', child: Text('重新命名歌手')),
                  if (ArtistRenames.originals(name).isNotEmpty) const PopupMenuItem(value: 'restore', child: Text('還原原本的名字')),
                  const PopupMenuItem(value: 'photo', child: Text('從手機選圖片')),
                  const PopupMenuItem(value: 'deezer', child: Text('從 Deezer 結果挑選')),
                  if (ArtistImages.hasCustom(name)) const PopupMenuItem(value: 'removePhoto', child: Text('移除自訂圖片')),
                ],
              ),
            if (kind == CollectionKind.favorites)
              IconButton(
                icon: const Icon(Icons.ios_share),
                tooltip: '複製／匯出歌單',
                onPressed: () => showExportSheet(context, name, tracks),
              ),
            if (kind == CollectionKind.folder)
              PopupMenuButton<String>(
                onSelected: (v) async {
                  switch (v) {
                    case 'queue':
                      await handler.enqueue(tracks);
                      if (context.mounted) toast(context, '已加入佇列');
                    case 'export':
                      await showExportSheet(context, name, tracks);
                    case 'lyrics':
                      await findLyrics(context, ref, tracks, title: name);
                    case 'covers':
                      await findCovers(context, ref, tracks);
                    case 'native':
                      await findNativeNames(context, ref, tracks);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'queue', child: Text('加入佇列')),
                  PopupMenuItem(value: 'export', child: Text('複製／匯出歌單')),
                  PopupMenuItem(value: 'lyrics', child: Text('找歌詞')),
                  PopupMenuItem(value: 'covers', child: Text('找封面')),
                  PopupMenuItem(value: 'native', child: Text('找原文歌名')),
                ],
              ),
            if (kind == CollectionKind.playlist)
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'rename') {
                    final n = await promptText(context, title: '重新命名', initial: name);
                    if (n != null && n.isNotEmpty) await db.renamePlaylist(playlistId!, n);
                  } else if (v == 'delete') {
                    final title = info?.name ?? name;
                    if (!await confirmDelete(context,
                        title: '刪除播放清單「$title」？', message: '歌曲本身不會被刪除，只會刪除這個播放清單。', action: '刪除')) {
                      return;
                    }
                    await db.deletePlaylist(playlistId!);
                    if (context.mounted) Navigator.pop(context);
                  } else if (info != null && v == 'cover') {
                    await pickPlaylistCover(context, ref, info);
                  } else if (info != null && v == 'resetCover') {
                    if (!await confirmDelete(context, title: '移除播放清單圖片？', message: '會改回使用第一首歌的封面。')) return;
                    await resetPlaylistCover(ref, info);
                  } else if (info != null && v == 'folder') {
                    await movePlaylistToFolder(context, ref, info);
                  } else if (v == 'queue') {
                    await handler.enqueue(tracks);
                    if (context.mounted) toast(context, '已加入佇列');
                  } else if (v == 'export') {
                    await showExportSheet(context, info?.name ?? name, tracks);
                  } else if (v == 'lyrics') {
                    await findLyrics(context, ref, tracks, title: info?.name ?? name);
                  } else if (v == 'covers') {
                    await findCovers(context, ref, tracks);
                  } else if (v == 'native') {
                    await findNativeNames(context, ref, tracks);
                  } else if (v == 'dedupe') {
                    final extra = tracks.length - withoutDuplicates(tracks).length;
                    if (extra == 0) {
                      toast(context, '沒有重複的歌曲');
                      return;
                    }
                    if (!await confirmDelete(context,
                        title: '移除 $extra 首重複的歌曲？',
                        message: '每首歌只保留第一次出現的位置，順序不變。檔案不會被刪除。')) {
                      return;
                    }
                    final n = await db.removePlaylistDuplicates(playlistId!);
                    if (context.mounted) toast(context, '已移除 $n 首重複的歌曲');
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'rename', child: Text('重新命名')),
                  const PopupMenuItem(value: 'queue', child: Text('加入佇列')),
                  const PopupMenuItem(value: 'cover', child: Text('更換播放清單圖片')),
                  if (info?.cover != null) const PopupMenuItem(value: 'resetCover', child: Text('移除播放清單圖片')),
                  const PopupMenuItem(value: 'folder', child: Text('移到資料夾')),
                  const PopupMenuItem(value: 'export', child: Text('複製／匯出歌單')),
                  const PopupMenuItem(value: 'lyrics', child: Text('找歌詞')),
                  const PopupMenuItem(value: 'covers', child: Text('找封面')),
                  const PopupMenuItem(value: 'native', child: Text('找原文歌名')),
                  const PopupMenuItem(value: 'dedupe', child: Text('移除重複的歌曲')),
                  const PopupMenuItem(value: 'delete', child: Text('刪除播放清單')),
                ],
              ),
          ],
          flexibleSpace: FlexibleSpaceBar(
            background: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [color, theme.scaffoldBackgroundColor]),
              ),
              padding: const EdgeInsets.fromLTRB(20, 72, 20, 16),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                kind == CollectionKind.favorites
                    ? Container(
                        width: 160,
                        height: 160,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          gradient: const LinearGradient(colors: [Color(0xFF3A2FD8), AppColors.accent], begin: Alignment.topLeft, end: Alignment.bottomRight),
                        ),
                        child: const Icon(Icons.favorite, size: 64, color: Colors.white),
                      )
                    : ZoomableArt(
                        art: art,
                        child: ArtImage(art, size: 160, circle: kind == CollectionKind.artist, icon: switch (kind) {
                          CollectionKind.artist => Icons.person,
                          CollectionKind.folder => Icons.folder,
                          _ => Icons.album,
                        }),
                      ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(mainAxisAlignment: MainAxisAlignment.end, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(label, style: theme.textTheme.labelMedium),
                    Text(info?.name ?? name, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900)),
                    const SizedBox(height: 8),
                    Text(subtitle, style: theme.textTheme.bodySmall),
                  ]),
                ),
              ]),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
              // Lit while this list plays shuffled: tap to shuffle-play it, tap
              // again to go back to the list's order (the song keeps playing).
              StreamBuilder<bool>(
                stream: handler.shuffleStream,
                builder: (context, snap) {
                  final lit = (snap.data ?? false) && handler.queueSource == pageKey;
                  return IconButton(
                    tooltip: lit ? '關閉隨機播放' : '隨機播放',
                    icon: Icon(Icons.shuffle, color: lit ? AppColors.accent : null),
                    onPressed: tracks.isEmpty
                        ? null
                        : () => lit
                            ? handler.setShuffleMode(AudioServiceShuffleMode.none)
                            : handler.playTracks(tracks, shuffle: true, source: pageKey),
                  );
                },
              ),
              IconButton(
                tooltip: '加入播放清單',
                icon: const Icon(Icons.playlist_add),
                onPressed: tracks.isEmpty ? null : () => showAddToPlaylist(context, ref, tracks),
              ),
              if (kind == CollectionKind.playlist)
                IconButton(
                  tooltip: '從本地音樂加入',
                  icon: const Icon(Icons.library_add_outlined),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => PickSongsPage(playlistId: playlistId!, playlistName: info?.name ?? name))),
                ),
              if (kind == CollectionKind.playlist)
                IconButton(
                  tooltip: '下載到這個播放清單',
                  icon: const Icon(Icons.download_for_offline_outlined),
                  onPressed: () => _downloadToPlaylist(context, ref),
                ),
              TrackSortButton(
                sort: sort,
                customLabel: switch (kind) {
                  CollectionKind.playlist => '自訂順序',
                  CollectionKind.favorites => '按讚順序',
                  CollectionKind.album => '曲目順序',
                  CollectionKind.smart => switch (smart!) {
                      SmartList.mostPlayed => '播放次數',
                      SmartList.notPlayedLately => '最久沒聽的在前',
                      _ => '最近加入的在前',
                    },
                  _ => '預設順序',
                },
                onChanged: (v) => ref.read(sortProvider(sortScope).notifier).set(v.encode()),
              ),
                  ]),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                iconSize: 32,
                style: IconButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.black, fixedSize: const Size(56, 56)),
                icon: const Icon(Icons.play_arrow),
                // In the list's order, unless this list's shuffle is lit.
                onPressed: tracks.isEmpty
                    ? null
                    : () {
                        final lit = handler.shuffled && handler.queueSource == pageKey;
                        handler.playTracks(tracks, shuffle: lit, inOrder: !lit, source: pageKey);
                      },
              ),
            ]),
          ),
        ),
        if (tracksAsync.isLoading && tracks.isEmpty)
          const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
        else if (tracks.isEmpty)
          const SliverFillRemaining(hasScrollBody: false, child: Center(child: Text('這裡還沒有歌曲')))
        else
        if (reorderable)
          // A playlist in its own order: drag the ≡ handle to move a song.
          SliverReorderableList(
            itemCount: tracks.length,
            onReorderItem: (from, to) => db.reorderPlaylist(playlistId!, from, to),
            proxyDecorator: (child, _, __) => Material(elevation: 6, color: theme.colorScheme.surfaceContainerHigh, child: child),
            itemBuilder: (context, i) => TrackTile(
              key: ValueKey('${tracks[i].id}#$i'),
              track: tracks[i],
              index: i,
              selectIndex: i,
              onTap: () => handler.playTracks(tracks, index: i, source: pageKey),
              onRemove: () => db.removeFromPlaylist(playlistId!, order[i]),
              // ≡ (three lines) at the far right, after the ⋮ menu.
              dragHandle: ReorderableDragStartListener(
                index: i,
                child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.menu)),
              ),
            ),
          )
        else
          SliverList.builder(
            itemCount: rows.length,
            itemBuilder: (context, j) {
              final i = rows[j];
              return TrackTile(
              track: tracks[i],
              index: i,
              selectIndex: i,
              showArt: kind != CollectionKind.album,
              onTap: () => handler.playTracks(tracks, index: i, source: pageKey),
              onRemove: kind == CollectionKind.playlist
                  ? () => db.removeFromPlaylist(playlistId!, order[i])
                  : kind == CollectionKind.favorites
                      ? () => db.setFavorite(tracks[i], false)
                      : null,
              removeLabel: kind == CollectionKind.favorites ? '從已按讚的歌曲移除' : '從此播放清單移除',
            );
            },
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ]),
      ),
    );
  }
}

extension on CollectionPage {
  /// Paste a song or playlist URL; finished songs go straight into this playlist.
  Future<void> _downloadToPlaylist(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController();
    var wholePlaylist = true;
    final url = await showDialog<String>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('下載到「$name」'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(hintText: '貼上歌曲或播放清單網址'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: wholePlaylist,
              onChanged: (v) => setState(() => wholePlaylist = v ?? true),
              title: const Text('網址是播放清單時，下載全部'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('下載')),
          ],
        ),
      ),
    );
    if (url == null || url.isEmpty) return;
    if (!url.startsWith('http')) {
      if (context.mounted) toast(context, '請輸入有效的網址');
      return;
    }
    if (!context.mounted || !await okToDownload(context, warn: ref.read(settingsProvider).wifiWarning)) return;
    ref.read(downloadServiceProvider).add(
          url,
          format: ref.read(settingsProvider).ytFormat,
          playlist: wholePlaylist,
          playlistId: playlistId,
          playlistName: name,
        );
    if (context.mounted) toast(context, '已加入下載佇列，完成後會加進「$name」');
  }
}

