import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../providers/providers.dart';
import '../../services/folder_tree.dart';
import '../../theme/app_theme.dart';
import '../widgets/art_image.dart';
import '../widgets/folder_actions.dart';
import '../widgets/track_selection.dart';
import '../widgets/track_tile.dart';

/// 瀏覽資料夾: the music folders and the download folder, then their
/// sub-folders and songs. [folder] null lists the starting folders. Folders
/// can be made, renamed and deleted here.
class FolderBrowserPage extends ConsumerStatefulWidget {
  const FolderBrowserPage({super.key, this.folder});
  final String? folder;

  @override
  ConsumerState<FolderBrowserPage> createState() => _FolderBrowserPageState();
}

class _FolderBrowserPageState extends ConsumerState<FolderBrowserPage> {
  void _open(String path) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => FolderBrowserPage(folder: path)));

  Future<void> _folderMenu(String folder, String action, {required bool isThisPage}) async {
    if (action == 'rename') {
      final to = await renameFolderDialog(context, ref, folder);
      if (to != null && isThisPage && mounted) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => FolderBrowserPage(folder: to)));
      }
    } else if (action == 'delete') {
      final gone = await deleteFolderDialog(context, ref, folder);
      if (gone && isThisPage && mounted) Navigator.of(context).pop();
    }
    if (mounted) setState(() {});
  }

  PopupMenuButton<String> _menu(String folder, {required bool isThisPage}) => PopupMenuButton<String>(
        onSelected: (v) => _folderMenu(folder, v, isThisPage: isThisPage),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'rename', child: Text('重新命名')),
          PopupMenuItem(value: 'delete', child: Text('刪除資料夾')),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final all = ref.watch(tracksProvider);
    final s = ref.watch(settingsProvider);
    final tree = FolderTree(all.value ?? const []);
    final handler = ref.read(audioHandlerProvider);
    final roots = tree.roots([...s.musicDirs, s.downloadDir]);
    final here = widget.folder;

    if (here == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('瀏覽資料夾')),
        body: ListView(children: [
          for (final r in roots)
            ListTile(
              leading: _folderBox(p.equals(r, s.downloadDir) ? Icons.download_for_offline_outlined : Icons.folder, 56),
              title: Text(p.basename(r).isEmpty ? r : p.basename(r)),
              subtitle: Text('${p.equals(r, s.downloadDir) ? '下載資料夾' : '音樂資料夾'} • ${tree.countIn(r)} 首歌曲\n$r',
                  style: TextStyle(color: muted)),
              isThreeLine: true,
              onTap: () => _open(r),
            ),
        ]),
      );
    }

    // The music / download folders themselves are managed in 設定 → 音樂庫.
    final isRoot = roots.any((r) => p.equals(r, here));
    final listing = tree.list(here, disk: FolderTree.diskFolders(here));
    final songs = listing.songs;
    return Scaffold(
      appBar: AppBar(
        title: Text(p.basename(here)),
        actions: [
          IconButton(
            tooltip: '隨機播放這個資料夾',
            icon: const Icon(Icons.shuffle),
            onPressed: tree.countIn(here) == 0 ? null : () => handler.playTracks(tree.everything(here), shuffle: true),
          ),
          IconButton(
            tooltip: '新增資料夾',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: () async {
              await createFolderDialog(context, ref, here);
              if (mounted) setState(() {});
            },
          ),
          if (!isRoot) _menu(here, isThisPage: true),
        ],
      ),
      body: TrackSelectionScope(
        tracks: songs,
        child: listing.folders.isEmpty && songs.isEmpty
            ? Center(child: Text(all.isLoading ? '讀取中…' : '這個資料夾是空的', style: TextStyle(color: muted)))
            : ListView(children: [
                for (final f in listing.folders)
                  ListTile(
                    leading: f.art == null ? _folderBox(Icons.folder, 56) : ArtImage(f.art, size: 56),
                    title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('資料夾 • ${f.count} 首歌曲', style: TextStyle(color: muted)),
                    trailing: _menu(f.path, isThisPage: false),
                    onTap: () => _open(f.path),
                  ),
                for (var i = 0; i < songs.length; i++)
                  TrackTile(
                    track: songs[i],
                    index: i,
                    selectIndex: i,
                    onTap: () => handler.playTracks(songs, index: i),
                  ),
                const SizedBox(height: 24),
              ]),
      ),
    );
  }

  static Widget _folderBox(IconData icon, double size) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), color: AppColors.accent.withValues(alpha: 0.18)),
        child: Icon(icon, color: AppColors.accent, size: size * 0.45),
      );
}
