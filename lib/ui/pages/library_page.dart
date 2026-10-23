import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../theme/app_theme.dart';
import '../widgets/art_image.dart';
import '../widgets/dialogs.dart';
import '../widgets/track_selection.dart';
import '../widgets/track_tile.dart';
import 'collection_page.dart';
import 'folder_page.dart';
import 'podcasts_page.dart';

enum _Filter { playlists, albums, artists, songs, podcasts }

const _labels = {
  _Filter.playlists: '播放清單',
  _Filter.albums: '專輯',
  _Filter.artists: '演出者',
  _Filter.songs: '歌曲',
  _Filter.podcasts: 'Podcast',
};

class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  _Filter _filter = _Filter.playlists;

  void _push(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));

  Future<void> _newPlaylist() async {
    final db = ref.read(dbProvider);
    final count = (ref.read(playlistsProvider).value ?? const []).length;
    final name = await promptText(context, title: '為播放清單命名', hint: '我的播放清單 #${count + 1}');
    if (name == null) return;
    final n = name.isEmpty ? '我的播放清單 #${count + 1}' : name;
    final id = await db.createPlaylist(n);
    if (mounted) _push(CollectionPage.playlist(id, n));
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    Widget body;
    switch (_filter) {
      case _Filter.playlists:
        final lists = ref.watch(topLevelPlaylistsProvider).value ?? const [];
        final playlistFolders = ref.watch(playlistFoldersProvider).value ?? const [];
        final favCount = ref.watch(favoriteIdsProvider).value?.length ?? 0;
        final folders = ref.watch(libraryFoldersProvider).value ?? const [];
        body = ListView(children: [
          ListTile(
            leading: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                gradient: const LinearGradient(colors: [Color(0xFF3A2FD8), AppColors.accent]),
              ),
              child: const Icon(Icons.favorite, color: Colors.white),
            ),
            title: const Text('已按讚的歌曲'),
            subtitle: Text('播放清單 • $favCount 首歌曲', style: TextStyle(color: muted)),
            onTap: () => _push(CollectionPage.favorites()),
          ),
          for (final f in folders)
            ListTile(
              leading: folderIcon(context, f, 56),
              title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${f.path == null ? '本機' : '資料夾'} • ${f.count} 首歌曲', style: TextStyle(color: muted)),
              onTap: () => _push(CollectionPage.folder(f.path, f.name)),
            ),
          ListTile(
            leading: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), color: Theme.of(context).colorScheme.surfaceContainerHigh),
              child: const Icon(Icons.add),
            ),
            title: const Text('建立播放清單'),
            onTap: _newPlaylist,
          ),
          ListTile(
            leading: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), color: Theme.of(context).colorScheme.surfaceContainerHigh),
              child: const Icon(Icons.create_new_folder_outlined),
            ),
            title: const Text('建立資料夾'),
            onTap: () => createPlaylistFolder(context, ref),
          ),
          for (final f in playlistFolders)
            ListTile(
              leading: PlaylistFolderArt(folder: f, size: 56),
              title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('資料夾 • ${f.count} 個播放清單', style: TextStyle(color: muted)),
              onTap: () => _push(FolderPage(folderId: f.id, name: f.name)),
            ),
          for (final pl in lists)
            ListTile(
              leading: ArtImage(pl.art, size: 56, icon: Icons.queue_music),
              title: Text(pl.name),
              subtitle: Text('播放清單 • ${pl.count} 首歌曲', style: TextStyle(color: muted)),
              onTap: () => _push(CollectionPage.playlist(pl.id, pl.name)),
            ),
        ]);
      case _Filter.albums:
        final albums = ref.watch(albumsProvider).value ?? const [];
        body = ListView.builder(
          itemCount: albums.length,
          itemBuilder: (_, i) => ListTile(
            leading: ArtImage(albums[i].art, size: 56),
            title: Text(albums[i].name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('專輯 • ${albums[i].artist}', maxLines: 1, style: TextStyle(color: muted)),
            onTap: () => _push(CollectionPage.album(albums[i].name)),
          ),
        );
      case _Filter.artists:
        final artists = ref.watch(artistsProvider).value ?? const [];
        body = ListView.builder(
          itemCount: artists.length,
          itemBuilder: (_, i) => ListTile(
            leading: ArtImage(artists[i].art, size: 56, circle: true, icon: Icons.person),
            title: Text(artists[i].name),
            subtitle: Text('演出者 • ${artists[i].count} 首', style: TextStyle(color: muted)),
            onTap: () => _push(CollectionPage.artist(artists[i].name)),
          ),
        );
      case _Filter.songs:
        final tracks = ref.watch(tracksProvider).value ?? const [];
        final handler = ref.read(audioHandlerProvider);
        body = TrackSelectionScope(
          tracks: tracks,
          child: ListView.builder(
          itemCount: tracks.length + 1,
          itemBuilder: (_, i) => i == 0
              ? ListTile(
                  leading: const Icon(Icons.shuffle, color: AppColors.accent),
                  title: Text('隨機播放全部（${tracks.length} 首）'),
                  onTap: tracks.isEmpty ? null : () => handler.playTracks(tracks, shuffle: true),
                )
              : TrackTile(track: tracks[i - 1], selectIndex: i - 1, onTap: () => handler.playTracks(tracks, index: i - 1)),
          ),
        );
      case _Filter.podcasts:
        body = const PodcastList();
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('你的音樂庫'),
        actions: [IconButton(icon: const Icon(Icons.add), tooltip: '建立播放清單', onPressed: _newPlaylist)],
      ),
      body: Column(children: [
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final f in _Filter.values)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    label: Text(_labels[f]!),
                    selected: _filter == f,
                    showCheckmark: false,
                    labelStyle: TextStyle(color: _filter == f ? Colors.black : null),
                    onSelected: (_) => setState(() => _filter = f),
                  ),
                ),
            ],
          ),
        ),
        Expanded(child: body),
      ]),
    );
  }
}

/// Square folder / phone icon used for music-folder entries in the library.
Widget folderIcon(BuildContext context, LibraryFolder f, double size) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), color: AppColors.accent.withValues(alpha: 0.18)),
      child: Icon(f.path == null ? Icons.phone_android : Icons.folder, color: AppColors.accent, size: size * 0.45),
    );
