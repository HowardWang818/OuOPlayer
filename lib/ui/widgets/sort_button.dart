import 'package:flutter/material.dart';

import '../../services/track_sort.dart';

/// Sort menu for a song list plus an ↑/↓ button for the direction.
class TrackSortButton extends StatelessWidget {
  const TrackSortButton({super.key, required this.sort, required this.onChanged, this.customLabel = '預設順序', this.allowCustom = true});

  final TrackSort sort;
  final ValueChanged<TrackSort> onChanged;
  final String customLabel;
  final bool allowCustom;

  @override
  Widget build(BuildContext context) {
    final keys = TrackSortKey.values.where((k) => allowCustom || k != TrackSortKey.custom);
    String label(TrackSortKey k) => k == TrackSortKey.custom ? customLabel : k.label;
    final up = !sort.descending;
    final direction = switch (sort.key) {
      TrackSortKey.custom => up ? '照原本順序' : '倒過來（最後的在最上面）',
      TrackSortKey.added => up ? '由舊到新' : '由新到舊',
      TrackSortKey.duration => up ? '由短到長' : '由長到短',
      _ => up ? '由 A 到 Z' : '由 Z 到 A',
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      PopupMenuButton<TrackSortKey>(
        tooltip: '排序：${label(sort.key)}',
        icon: const Icon(Icons.sort),
        onSelected: (k) => onChanged(TrackSort(k, descending: sort.descending)),
        itemBuilder: (_) => [
          for (final k in keys) CheckedPopupMenuItem(value: k, checked: k == sort.key, child: Text(label(k))),
        ],
      ),
      _DirectionButton(up: up, tooltip: direction, onPressed: () => onChanged(TrackSort(sort.key, descending: !sort.descending))),
    ]);
  }
}

/// Sort menu for the album and artist lists plus an ↑/↓ button. The arrow
/// shows the real direction: 「歌曲數」 and 「最近加入」 start biggest /
/// newest first (↓).
class GroupSortButton extends StatelessWidget {
  const GroupSortButton({super.key, required this.sort, required this.onChanged});

  final GroupSort sort;
  final ValueChanged<GroupSort> onChanged;

  @override
  Widget build(BuildContext context) {
    final up = sort.key == GroupSortKey.name ? !sort.descending : sort.descending;
    final direction = switch (sort.key) {
      GroupSortKey.name => up ? '由 A 到 Z' : '由 Z 到 A',
      GroupSortKey.count => up ? '由少到多' : '由多到少',
      GroupSortKey.recent => up ? '由舊到新' : '由新到舊',
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      PopupMenuButton<GroupSortKey>(
        tooltip: '排序：${sort.key.label}',
        icon: const Icon(Icons.sort),
        onSelected: (k) => onChanged(GroupSort(k)),
        itemBuilder: (_) => [
          for (final k in GroupSortKey.values) CheckedPopupMenuItem(value: k, checked: k == sort.key, child: Text(k.label)),
        ],
      ),
      _DirectionButton(up: up, tooltip: direction, onPressed: () => onChanged(GroupSort(sort.key, descending: !sort.descending))),
    ]);
  }
}

class _DirectionButton extends StatelessWidget {
  const _DirectionButton({required this.up, required this.tooltip, required this.onPressed});
  final bool up;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(up ? Icons.arrow_upward : Icons.arrow_downward),
      );
}
