import 'package:flutter/material.dart';

import '../../services/track_sort.dart';

/// Sort menu for a song list: one entry per [TrackSortKey] (picking the
/// current one again reverses it) plus 「反向排序」.
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
    return PopupMenuButton<Object>(
      tooltip: '排序：${label(sort.key)}${sort.descending ? '（反向）' : ''}',
      icon: const Icon(Icons.sort),
      onSelected: (v) {
        if (v == 'reverse') {
          onChanged(TrackSort(sort.key, descending: !sort.descending));
        } else if (v is TrackSortKey) {
          onChanged(TrackSort(v, descending: v == sort.key ? !sort.descending : false));
        }
      },
      itemBuilder: (_) => [
        for (final k in keys)
          CheckedPopupMenuItem(value: k, checked: k == sort.key, child: Text(label(k))),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(value: 'reverse', checked: sort.descending, child: const Text('反向排序')),
      ],
    );
  }
}

/// Sort menu for the album and artist lists.
class GroupSortButton extends StatelessWidget {
  const GroupSortButton({super.key, required this.sort, required this.onChanged});

  final GroupSort sort;
  final ValueChanged<GroupSort> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<Object>(
      tooltip: '排序：${sort.key.label}${sort.descending ? '（反向）' : ''}',
      icon: const Icon(Icons.sort),
      onSelected: (v) {
        if (v == 'reverse') {
          onChanged(GroupSort(sort.key, descending: !sort.descending));
        } else if (v is GroupSortKey) {
          onChanged(GroupSort(v, descending: v == sort.key ? !sort.descending : false));
        }
      },
      itemBuilder: (_) => [
        for (final k in GroupSortKey.values)
          CheckedPopupMenuItem(value: k, checked: k == sort.key, child: Text(k.label)),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(value: 'reverse', checked: sort.descending, child: const Text('反向排序')),
      ],
    );
  }
}
