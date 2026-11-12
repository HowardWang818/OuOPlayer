import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import 'song_actions.dart';

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
  const TrackSelectionScope({super.key, required this.tracks, required this.child, this.onRemove, this.removeLabel, this.onFilter});

  /// Pages with a song list, newest last, for the shortcuts below.
  static final _open = <_TrackSelectionScopeState>[];

  static _TrackSelectionScopeState? get _front => _open.reversed.where((s) => s.mounted && ModalRoute.of(s.context)?.isCurrent == true).firstOrNull;

  /// 全選 on the list page in front, if there is one.
  static void selectAllInFront() {
    final s = _front;
    s?._selection.selectAll(s.widget.tracks.length);
  }

  /// Opens or closes the search box of the list page in front, if it has one.
  static void filterInFront() => _front?.widget.onFilter?.call();

  /// Opens or closes this page's search box.
  final VoidCallback? onFilter;

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
  void initState() {
    super.initState();
    TrackSelectionScope._open.add(this);
  }

  @override
  void didUpdateWidget(TrackSelectionScope old) {
    super.didUpdateWidget(old);
    // The list changed under us (e.g. songs removed): drop stale indexes.
    if (old.tracks.length != widget.tracks.length) _selection.clear();
  }

  @override
  void dispose() {
    TrackSelectionScope._open.remove(this);
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
    final handler = ref.read(audioHandlerProvider);

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
                // The selection clears afterwards: clearing first takes this
                // bar (and its context) away before a dialog can open.
                final ok = await runSongAction(context, ref, v, picked,
                    onRemove: scope.onRemove == null ? null : () => scope.onRemove!(indexes), removeLabel: scope.removeLabel);
                if (ok && context.mounted) selection.clear();
              },
              itemBuilder: (_) => [
                for (final a in songActions(ref, picked, removeLabel: scope.onRemove == null ? null : (scope.removeLabel ?? '從此播放清單移除')))
                  PopupMenuItem(value: a.id, child: Text(a.label, style: a.danger ? const TextStyle(color: Colors.redAccent) : null)),
              ],
            ),
          ]),
        ),
      ),
    );
  }
}
