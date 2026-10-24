import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/folder_ops.dart';
import '../../services/folder_tree.dart';
import '../../theme/app_theme.dart';
import 'dialogs.dart';
import 'track_tile.dart';

/// Asks for a name and creates a folder inside [parent]. Returns its path.
Future<String?> createFolderDialog(BuildContext context, WidgetRef ref, String parent) async {
  final name = await promptText(context, title: '新增資料夾', hint: '資料夾名稱', ok: '建立');
  if (name == null || !context.mounted) return null;
  try {
    final path = await FolderOps(ref.read(dbProvider)).create(parent, name);
    if (context.mounted) toast(context, '已建立「${p.basename(path)}」');
    return path;
  } catch (e) {
    if (context.mounted) toast(context, '無法建立資料夾：$e');
    return null;
  }
}

/// Renames [folder]; returns its new path (null if nothing changed).
Future<String?> renameFolderDialog(BuildContext context, WidgetRef ref, String folder) async {
  final name = await promptText(context, title: '重新命名資料夾', initial: p.basename(folder));
  if (name == null || name.trim() == p.basename(folder) || !context.mounted) return null;
  final inside = FolderTree(await ref.read(tracksProvider.future)).everything(folder);
  try {
    final report = await FolderOps(ref.read(dbProvider)).renameFolder(folder, name, inside);
    await ref.read(audioHandlerProvider).relocate(report.moved);
    if (!context.mounted) return null;
    toast(context, report.failed == 0 ? '已改名為「${name.trim()}」' : '已改名，但有 ${report.failed} 首沒辦法移動，留在原本的資料夾');
    return p.join(p.dirname(folder), name.trim());
  } catch (e) {
    if (context.mounted) toast(context, '無法重新命名：$e');
    return null;
  }
}

/// Deletes [folder] with its songs (after the usual warning). Returns true if
/// the folder is gone.
Future<bool> deleteFolderDialog(BuildContext context, WidgetRef ref, String folder) async {
  final name = p.basename(folder);
  final inside = FolderTree(await ref.read(tracksProvider.future)).everything(folder);
  if (!context.mounted) return false;
  if (inside.isEmpty) {
    if (!await confirmDelete(context, title: '刪除資料夾「$name」？', message: '這個資料夾裡沒有音樂庫的歌曲。', action: '刪除')) return false;
  } else if (!await deleteTrackFiles(context, ref, inside, title: '刪除資料夾「$name」和裡面的 ${inside.length} 首歌？')) {
    return false;
  }
  final gone = await FolderOps.removeEmptyDirs(folder);
  if (context.mounted) {
    toast(context, gone ? '已刪除資料夾「$name」' : '歌曲已刪除，但資料夾裡還有其他 App 的檔案，所以資料夾留著');
  }
  return gone;
}

/// 選取 →「移到資料夾…」: pick a folder (or make one), then move the songs.
Future<bool> moveTracksDialog(BuildContext context, WidgetRef ref, List<Track> tracks) async {
  final local = [for (final t in tracks) if (!t.isRemote && t.uri.isNotEmpty && t.source != TrackSource.missing) t];
  if (local.isEmpty) return false;
  final dest = await Navigator.of(context, rootNavigator: true)
      .push<String>(MaterialPageRoute(builder: (_) => FolderPickerPage(title: '移動 ${local.length} 首到…')));
  if (dest == null || !context.mounted) return false;
  try {
    final report = await FolderOps(ref.read(dbProvider)).moveTracks(local, dest);
    await ref.read(audioHandlerProvider).relocate(report.moved);
    if (!context.mounted) return true;
    final n = report.moved.length;
    toast(context, report.failed == 0
        ? (n == 0 ? '歌曲已經在「${p.basename(dest)}」裡' : '已移動 $n 首到「${p.basename(dest)}」')
        : '已移動 $n 首，有 ${report.failed} 首沒辦法移動');
    return true;
  } catch (e) {
    if (context.mounted) toast(context, '移動失敗：$e');
    return false;
  }
}

/// Chooses a folder inside the music / download folders. Pops its path.
class FolderPickerPage extends ConsumerStatefulWidget {
  const FolderPickerPage({super.key, required this.title, this.folder});
  final String title;
  final String? folder;

  @override
  ConsumerState<FolderPickerPage> createState() => _FolderPickerPageState();
}

class _FolderPickerPageState extends ConsumerState<FolderPickerPage> {
  late String? _here = widget.folder;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final tree = FolderTree(ref.watch(tracksProvider).value ?? const []);
    final roots = tree.roots([...s.musicDirs, s.downloadDir]);
    final here = _here;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final folders = here == null
        ? [for (final r in roots) SubFolder(r, p.basename(r), tree.countIn(r), null)]
        : tree.list(here, disk: FolderTree.diskFolders(here)).folders;
    return PopScope(
      canPop: here == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || here == null) return;
        setState(() => _here = roots.any((r) => p.equals(r, here)) ? null : p.dirname(here));
      },
      child: Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: Column(children: [
          if (here != null)
            ListTile(
              leading: const Icon(Icons.folder_open, color: AppColors.accent),
              title: Text(p.basename(here), style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(here, style: TextStyle(color: muted)),
            ),
          Expanded(
            child: ListView(children: [
              if (here != null)
                ListTile(
                  leading: const Icon(Icons.create_new_folder_outlined),
                  title: const Text('新增資料夾'),
                  onTap: () async {
                    final made = await createFolderDialog(context, ref, here);
                    if (made != null) setState(() => _here = made);
                  },
                ),
              for (final f in folders)
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(f.name),
                  subtitle: Text('${f.count} 首歌曲', style: TextStyle(color: muted)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => setState(() => _here = f.path),
                ),
            ]),
          ),
          if (here != null)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.drive_file_move_outline),
                    label: Text('移到「${p.basename(here)}」'),
                    onPressed: () => Navigator.pop(context, here),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
