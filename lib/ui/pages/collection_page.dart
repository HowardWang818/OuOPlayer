import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../theme/app_theme.dart';
import '../widgets/art_image.dart';
import '../widgets/dialogs.dart';
import '../widgets/track_tile.dart';

enum CollectionKind { album, artist, playlist, favorites, allSongs }

/// Album / artist / playlist / liked-songs page with a Spotify-like header.
class CollectionPage extends ConsumerWidget {
  const CollectionPage._(this.kind, {this.name = '', this.playlistId});

  factory CollectionPage.album(String album) => CollectionPage._(CollectionKind.album, name: album);
  factory CollectionPage.artist(String artist) => CollectionPage._(CollectionKind.artist, name: artist);
  factory CollectionPage.playlist(int id, String name) => CollectionPage._(CollectionKind.playlist, name: name, playlistId: id);
  factory CollectionPage.favorites() => const CollectionPage._(CollectionKind.favorites, name: '已按讚的歌曲');
  factory CollectionPage.allSongs() => const CollectionPage._(CollectionKind.allSongs, name: '所有歌曲');

  final CollectionKind kind;
  final String name;
  final int? playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracksAsync = switch (kind) {
      CollectionKind.album => ref.watch(albumTracksProvider(name)),
      CollectionKind.artist => ref.watch(artistTracksProvider(name)),
      CollectionKind.playlist => ref.watch(playlistTracksProvider(playlistId!)),
      CollectionKind.favorites => ref.watch(favoritesProvider),
      CollectionKind.allSongs => ref.watch(tracksProvider),
    };
    final tracks = tracksAsync.value ?? const <Track>[];
    final art = tracks.where((t) => t.art != null).firstOrNull?.art;
    final color = ref.watch(artColorProvider(art)).value ?? AppColors.accent.withValues(alpha: 0.5);
    final theme = Theme.of(context);
    final handler = ref.read(audioHandlerProvider);
    final db = ref.read(dbProvider);

    final label = switch (kind) {
      CollectionKind.album => '專輯',
      CollectionKind.artist => '演出者',
      CollectionKind.playlist => '播放清單',
      _ => '播放清單',
    };
    final totalMs = tracks.fold<int>(0, (s, t) => s + (t.durationMs ?? 0));
    final subtitle = [
      if (kind == CollectionKind.album && tracks.isNotEmpty) tracks.first.artist,
      '${tracks.length} 首歌曲',
      if (totalMs > 0) '約 ${(totalMs / 60000).round()} 分鐘',
    ].join(' • ');

    return Scaffold(
      body: CustomScrollView(slivers: [
        SliverAppBar(
          pinned: true,
          expandedHeight: 300,
          backgroundColor: Color.lerp(color, theme.scaffoldBackgroundColor, 0.3),
          actions: [
            if (kind == CollectionKind.playlist)
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'rename') {
                    final n = await promptText(context, title: '重新命名', initial: name);
                    if (n != null && n.isNotEmpty) await db.renamePlaylist(playlistId!, n);
                  } else if (v == 'delete') {
                    await db.deletePlaylist(playlistId!);
                    if (context.mounted) Navigator.pop(context);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('重新命名')),
                  PopupMenuItem(value: 'delete', child: Text('刪除播放清單')),
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
                    : ArtImage(art, size: 160, circle: kind == CollectionKind.artist, icon: kind == CollectionKind.artist ? Icons.person : Icons.album),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(mainAxisAlignment: MainAxisAlignment.end, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(label, style: theme.textTheme.labelMedium),
                    Text(name, maxLines: 2, overflow: TextOverflow.ellipsis,
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
              IconButton(
                tooltip: '隨機播放',
                icon: const Icon(Icons.shuffle),
                onPressed: tracks.isEmpty ? null : () => handler.playTracks(tracks, shuffle: true),
              ),
              IconButton(
                tooltip: '加入播放清單',
                icon: const Icon(Icons.playlist_add),
                onPressed: tracks.isEmpty ? null : () => showAddToPlaylist(context, ref, tracks),
              ),
              const Spacer(),
              IconButton.filled(
                iconSize: 32,
                style: IconButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.black, fixedSize: const Size(56, 56)),
                icon: const Icon(Icons.play_arrow),
                onPressed: tracks.isEmpty ? null : () => handler.playTracks(tracks),
              ),
            ]),
          ),
        ),
        if (tracksAsync.isLoading && tracks.isEmpty)
          const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
        else if (tracks.isEmpty)
          const SliverFillRemaining(hasScrollBody: false, child: Center(child: Text('這裡還沒有歌曲')))
        else
          SliverList.builder(
            itemCount: tracks.length,
            itemBuilder: (context, i) => TrackTile(
              track: tracks[i],
              index: i,
              showArt: kind != CollectionKind.album,
              onTap: () => handler.playTracks(tracks, index: i),
              onRemove: kind == CollectionKind.playlist
                  ? () => db.removeFromPlaylist(playlistId!, i)
                  : kind == CollectionKind.favorites
                      ? () => db.setFavorite(tracks[i], false)
                      : null,
              removeLabel: kind == CollectionKind.favorites ? '從已按讚的歌曲移除' : '從此播放清單移除',
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ]),
    );
  }
}
