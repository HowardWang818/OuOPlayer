import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/file_trash.dart';
import 'dialogs.dart';
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
                  case 'copy':
                    await Clipboard.setData(ClipboardData(text: picked.map((t) => '${t.title} - ${t.artist}').join('\n')));
                    if (context.mounted) done('已複製');
                  case 'delete':
                    if (await deleteTrackFiles(context, ref, local)) selection.clear();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'queue', child: Text('加入佇列')),
                const PopupMenuItem(value: 'playlist', child: Text('加入播放清單')),
                const PopupMenuItem(value: 'like', child: Text('加到已按讚的歌曲')),
                if (scope.onRemove != null) PopupMenuItem(value: 'remove', child: Text(scope.removeLabel ?? '從此播放清單移除')),
                const PopupMenuItem(value: 'copy', child: Text('複製「歌名 - 歌手」')),
                if (local.isNotEmpty)
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('刪除檔案（${local.length} 首，移到$trashName）', style: const TextStyle(color: Colors.redAccent)),
                  ),
              ],
            ),
          ]),
        ),
      ),
    );
  }
}
