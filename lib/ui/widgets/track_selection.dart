import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/file_trash.dart';
import '../pages/cover_fix_page.dart';
import '../pages/lyrics_batch_page.dart';
import 'batch_edit_dialog.dart';
import 'dialogs.dart';
import 'export_sheet.dart';
import 'folder_actions.dart';
import 'track_tile.dart';

/// Which rows of a track list are selected (by index, since a playlist can
/// hold the same song twice). Long-press (or right-click) starts selecting.
class TrackSelection extends ChangeNotifier {
  final Set<int> selected = {};
  int? _anchor;

  bool get active => selected.isNotEmpty;

  /// Toggle one row; with [range] (Shift on desktop) select from the last
  /// toggled row to this one.
  void toggle(int i, {bool range = false}) {
    final anchor = _anchor;
    if (range && anchor != null) {
      final (a, b) = anchor < i ? (anchor, i) : (i, anchor);
      for (var k = a; k <= b; k++) {
        selected.add(k);
      }
    } else if (!selected.remove(i)) {
      selected.add(i);
    }
    _anchor = i;
    notifyListeners();
  }

  void selectAll(int count) {
    selected.addAll(List.generate(count, (i) => i));
    notifyListeners();
  }

  void clear() {
    selected.clear();
    _anchor = null;
    notifyListeners();
  }

  static TrackSelection? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SelectionInherited>()?.notifier;
}

class _SelectionInherited extends InheritedNotifier<TrackSelection> {
  const _SelectionInherited({required super.notifier, required super.child});
}

/// Wraps a page with a track list. While rows are selected, an action bar
/// slides over the top of the page.
class TrackSelectionScope extends StatefulWidget {
  const TrackSelectionScope({super.key, required this.tracks, required this.child, this.onRemove, this.removeLabel});

  /// The list the row indexes refer to.
  final List<Track> tracks;
  final Widget child;

  /// "Remove from this playlist" for the selected rows (indexes, ascending).
  final Future<void> Function(List<int> indexes)? onRemove;
  final String? removeLabel;

  @override
  State<TrackSelectionScope> createState() => _TrackSelectionScopeState();
}

class _TrackSelectionScopeState extends State<TrackSelectionScope> {
  final _selection = TrackSelection();

  @override
  void didUpdateWidget(TrackSelectionScope old) {
    super.didUpdateWidget(old);
    // The list changed under us (e.g. songs removed): drop stale indexes.
    if (old.tracks.length != widget.tracks.length) _selection.clear();
  }

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _SelectionInherited(
      notifier: _selection,
      child: ListenableBuilder(
        listenable: _selection,
        builder: (context, child) => PopScope(
          // Back leaves selection mode first.
          canPop: !_selection.active,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _selection.clear();
          },
          child: Stack(children: [
            child!,
            if (_selection.active)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _SelectionBar(selection: _selection, scope: widget),
              ),
          ]),
        ),
        child: widget.child,
      ),
    );
  }
}

class _SelectionBar extends ConsumerWidget {
  const _SelectionBar({required this.selection, required this.scope});
  final TrackSelection selection;
  final TrackSelectionScope scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final indexes = selection.selected.where((i) => i < scope.tracks.length).toList()..sort();
    final picked = [for (final i in indexes) scope.tracks[i]];
    final local = picked.where((t) => t.source == TrackSource.local || t.source == TrackSource.download).toList();
    final handler = ref.read(audioHandlerProvider);

    void done(String msg) {
      selection.clear();
      toast(context, msg);
    }

    return Material(
      elevation: 4,
      color: cs.surfaceContainerHigh,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 56,
          child: Row(children: [
            IconButton(icon: const Icon(Icons.close), tooltip: '取消選取', onPressed: selection.clear),
            Expanded(child: Text('已選 ${picked.length} 首', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
            IconButton(
              icon: const Icon(Icons.select_all),
              tooltip: '全選',
              onPressed: () => selection.selectAll(scope.tracks.length),
            ),
            IconButton(
              icon: const Icon(Icons.play_arrow),
              tooltip: '播放',
              onPressed: () {
                handler.playTracks(picked);
                selection.clear();
              },
            ),
            PopupMenuButton<String>(
              tooltip: '更多',
              onSelected: (v) async {
                switch (v) {
                  case 'queue':
                    await handler.enqueue(picked);
                    if (context.mounted) done('已加入佇列');
                  case 'playlist':
                    await showAddToPlaylist(context, ref, picked);
                    selection.clear();
                  case 'like':
                    final db = ref.read(dbProvider);
                    for (final t in picked) {
                      await db.setFavorite(t, true);
                    }
                    if (context.mounted) done('已加到已按讚的歌曲');
                  case 'remove':
                    if (!await confirmDelete(context, title: '${scope.removeLabel ?? '從此播放清單移除'} ${indexes.length} 首？')) return;
                    await scope.onRemove!(indexes);
                    if (context.mounted) done('已移除 ${indexes.length} 首');
                  case 'export':
                    await showExportSheet(context, '已選的 ${picked.length} 首', picked);
                    selection.clear();
                  case 'edit':
                    await showBatchEdit(context, ref, local);
                    selection.clear();
                  case 'covers':
                    selection.clear();
                    await Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => CoverFixPage(tracks: local)));
                  case 'hide':
                    final where = await removalLines(ref, local);
                    if (!context.mounted) return;
                    if (!await confirmDelete(context,
                        title: '從音樂庫隱藏 ${local.length} 首？',
                        message: '檔案不會被刪除，重新掃描後會再出現在音樂庫。會從以下地方移除：\n${where.map((l) => '• $l').join('\n')}',
                        action: '隱藏')) {
                      return;
                    }
                    for (final t in local) {
                      await handler.removeTrack(t.id);
                    }
                    await ref.read(dbProvider).deleteTracks(local.map((t) => t.id));
                    if (context.mounted) done('已隱藏 ${local.length} 首');
                  case 'lyrics':
                    final picked = [...local];
                    selection.clear();
                    await findLyrics(context, picked, title: '已選的 ${picked.length} 首');
                  case 'move':
                    if (await moveTracksDialog(context, ref, local)) selection.clear();
                  case 'delete':
                    if (await deleteTrackFiles(context, ref, local)) selection.clear();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'queue', child: Text('加入佇列')),
                const PopupMenuItem(value: 'playlist', child: Text('加入播放清單')),
                const PopupMenuItem(value: 'like', child: Text('加到已按讚的歌曲')),
                if (scope.onRemove != null) PopupMenuItem(value: 'remove', child: Text(scope.removeLabel ?? '從此播放清單移除')),
                const PopupMenuItem(value: 'export', child: Text('複製／匯出資訊')),
                if (local.isNotEmpty) ...[
                  PopupMenuItem(value: 'edit', child: Text('編輯資訊（${local.length} 首）')),
                  PopupMenuItem(value: 'covers', child: Text('找正式封面（${local.length} 首）')),
                  PopupMenuItem(value: 'move', child: Text('移到資料夾…（${local.length} 首）')),
                  PopupMenuItem(value: 'lyrics', child: Text('找歌詞（${local.length} 首）')),
                  PopupMenuItem(value: 'hide', child: Text('從音樂庫隱藏（${local.length} 首）')),
                ],
                if (local.isNotEmpty)
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(ref.read(settingsProvider).deletePermanently ? '永久刪除檔案（${local.length} 首）' : '刪除檔案（${local.length} 首，移到$trashName）',
                        style: const TextStyle(color: Colors.redAccent)),
                  ),
              ],
            ),
          ]),
        ),
      ),
    );
  }
}
