import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../widgets/art_image.dart';
import '../widgets/dialogs.dart';
import 'collection_page.dart';

/// The playlists inside one library folder.
class FolderPage extends ConsumerWidget {
  const FolderPage({super.key, required this.folderId, required this.name});
  final int folderId;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folder = (ref.watch(playlistFoldersProvider).value ?? const []).where((f) => f.id == folderId).firstOrNull;
    final lists = ref.watch(folderPlaylistsProvider(folderId)).value ?? const [];
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final db = ref.read(dbProvider);
    final title = folder?.name ?? name;
    return Scaffold(
      appBar: AppBar(title: Text(title), actions: [
        PopupMenuButton<String>(
          onSelected: (v) async {
            if (v == 'rename') {
              final n = await promptText(context, title: '重新命名資料夾', initial: title);
              if (n != null && n.isNotEmpty) await db.renameFolder(folderId, n);
            } else if (v == 'delete') {
              final ok = await showDialog<bool>(
                context: context,
                useRootNavigator: true,
                builder: (ctx) => AlertDialog(
                  title: Text('刪除資料夾「$title」？'),
                  content: const Text('裡面的播放清單不會被刪除，會移回音樂庫最外層。'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('刪除資料夾')),
                  ],
                ),
              );
              if (ok == true) {
                await db.deleteFolder(folderId);
                if (context.mounted) Navigator.pop(context);
              }
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: Text('重新命名')),
            PopupMenuItem(value: 'delete', child: Text('刪除資料夾')),
          ],
        ),
      ]),
      body: lists.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text('資料夾是空的。\n在播放清單的 ⋮ 選單選「移到資料夾」就能放進來。', textAlign: TextAlign.center, style: TextStyle(color: muted)),
              ),
            )
          : ListView(children: [
              for (final pl in lists)
                ListTile(
                  leading: ArtImage(pl.art, size: 56, icon: Icons.queue_music),
                  title: Text(pl.name),
                  subtitle: Text('播放清單 • ${pl.count} 首歌曲', style: TextStyle(color: muted)),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CollectionPage.playlist(pl.id, pl.name))),
                ),
            ]),
    );
  }
}

/// Folder icon, or a 2x2 grid of the covers of the playlists inside.
class PlaylistFolderArt extends StatelessWidget {
  const PlaylistFolderArt({super.key, required this.folder, required this.size});
  final PlaylistFolder folder;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (folder.arts.length < 4) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), color: cs.surfaceContainerHigh),
        child: Icon(Icons.folder, size: size * 0.5, color: cs.onSurfaceVariant),
      );
    }
    final half = size / 2;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: size,
        height: size,
        child: Wrap(children: [for (final a in folder.arts) ArtImage(a, size: half, radius: 0)]),
      ),
    );
  }
}

Future<void> createPlaylistFolder(BuildContext context, WidgetRef ref) async {
  final name = await promptText(context, title: '為資料夾命名', hint: '新資料夾');
  if (name == null) return;
  await ref.read(dbProvider).createFolder(name.isEmpty ? '新資料夾' : name);
}

/// Pick a folder for a playlist (or take it out of its folder).
Future<void> movePlaylistToFolder(BuildContext context, WidgetRef ref, Playlist playlist) async {
  final db = ref.read(dbProvider);
  final folders = await db.folders();
  if (!context.mounted) return;
  await showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        ListTile(
          leading: const Icon(Icons.create_new_folder_outlined),
          title: const Text('新增資料夾'),
          onTap: () async {
            Navigator.pop(ctx);
            final name = await promptText(context, title: '為資料夾命名', hint: '新資料夾');
            if (name == null) return;
            final id = await db.createFolder(name.isEmpty ? '新資料夾' : name);
            await db.setPlaylistFolder(playlist.id, id);
            if (context.mounted) toast(context, '已移到「${name.isEmpty ? '新資料夾' : name}」');
          },
        ),
        if (playlist.folderId != null)
          ListTile(
            leading: const Icon(Icons.drive_file_move_rtl_outlined),
            title: const Text('移出資料夾'),
            onTap: () async {
              Navigator.pop(ctx);
              await db.setPlaylistFolder(playlist.id, null);
              if (context.mounted) toast(context, '已移到音樂庫最外層');
            },
          ),
        for (final f in folders)
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(f.name),
            trailing: f.id == playlist.folderId ? const Icon(Icons.check) : null,
            onTap: () async {
              Navigator.pop(ctx);
              await db.setPlaylistFolder(playlist.id, f.id);
              if (context.mounted) toast(context, '已移到「${f.name}」');
            },
          ),
      ]),
    ),
  );
}

/// Let the user pick an image as the playlist cover. A copy is kept in the
/// app's own folder, so deleting the original later is fine.
Future<void> pickPlaylistCover(BuildContext context, WidgetRef ref, Playlist playlist) async {
  final picked = await FilePicker.pickFiles(type: FileType.image, dialogTitle: '選擇封面圖片');
  final src = picked.firstOrNull?.path;
  if (src == null) return;
  final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'covers'));
  await dir.create(recursive: true);
  // A new name each time so cached images of the old cover aren't reused.
  final dest = p.join(dir.path, 'playlist_${playlist.id}_${DateTime.now().millisecondsSinceEpoch}${p.extension(src).toLowerCase()}');
  await File(src).copy(dest);
  await _deleteOldCover(playlist);
  await ref.read(dbProvider).setPlaylistCover(playlist.id, dest);
  if (context.mounted) toast(context, '已更換封面');
}

Future<void> resetPlaylistCover(WidgetRef ref, Playlist playlist) async {
  await _deleteOldCover(playlist);
  await ref.read(dbProvider).setPlaylistCover(playlist.id, null);
}

Future<void> _deleteOldCover(Playlist playlist) async {
  final old = playlist.cover;
  if (old == null) return;
  try {
    await File(old).delete();
  } catch (_) {}
}
