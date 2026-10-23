import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../theme/app_theme.dart';
import '../widgets/art_image.dart';
import '../widgets/dialogs.dart';
import '../widgets/sort_button.dart';
import '../../services/track_sort.dart';
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

  Widget _sortRow(String text, Widget button) => Padding(
        padding: const EdgeInsets.only(left: 16, right: 4),
        child: Row(children: [
          Expanded(child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
          button,
        ]),
      );

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
        final sort = GroupSort.decode(ref.watch(sortProvider('albums')));
        final albums = sort.apply(ref.watch(albumsProvider).value ?? const <Album>[],
            name: (a) => a.name, count: (a) => a.count, added: (a) => a.added);
        body = ListView.builder(
          itemCount: albums.length + 1,
          itemBuilder: (_, i) => i == 0
              ? _sortRow('${albums.length} 張專輯',
                  GroupSortButton(sort: sort, onChanged: (v) => ref.read(sortProvider('albums').notifier).set(v.encode())))
              : ListTile(
                  leading: ArtImage(albums[i - 1].art, size: 56),
                  title: Text(albums[i - 1].name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('專輯 • ${albums[i - 1].artist}', maxLines: 1, style: TextStyle(color: muted)),
                  onTap: () => _push(CollectionPage.album(albums[i - 1].name)),
                ),
        );
      case _Filter.artists:
        final sort = GroupSort.decode(ref.watch(sortProvider('artists')));
        final artists = sort.apply(ref.watch(artistsProvider).value ?? const <Artist>[],
            name: (a) => a.name, count: (a) => a.count, added: (a) => a.added);
        body = ListView.builder(
          itemCount: artists.length + 1,
          itemBuilder: (_, i) => i == 0
              ? _sortRow('${artists.length} 位演出者',
                  GroupSortButton(sort: sort, onChanged: (v) => ref.read(sortProvider('artists').notifier).set(v.encode())))
              : ListTile(
                  leading: ArtImage(artists[i - 1].art, size: 56, circle: true, icon: Icons.person),
                  title: Text(artists[i - 1].name),
                  subtitle: Text('演出者 • ${artists[i - 1].count} 首', style: TextStyle(color: muted)),
                  onTap: () => _push(CollectionPage.artist(artists[i - 1].name)),
                ),
        );
      case _Filter.songs:
        final sort = TrackSort.decode(ref.watch(sortProvider('songs')), fallback: const TrackSort(TrackSortKey.title));
        final all = ref.watch(tracksProvider).value ?? const <Track>[];
        final tracks = [for (final i in sort.order(all)) all[i]];
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
                  trailing: TrackSortButton(
                    sort: sort,
                    allowCustom: false,
                    onChanged: (v) => ref.read(sortProvider('songs').notifier).set(v.encode()),
                  ),
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
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.add),
            tooltip: '建立',
            onSelected: (v) => v == 'folder' ? createPlaylistFolder(context, ref) : _newPlaylist(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'playlist', child: ListTile(leading: Icon(Icons.queue_music), title: Text('建立播放清單'))),
              PopupMenuItem(value: 'folder', child: ListTile(leading: Icon(Icons.create_new_folder_outlined), title: Text('建立資料夾'))),
            ],
          ),
        ],
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
