import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../providers/providers.dart';
import 'dialogs.dart';

/// 清除播放資料: tick what to remove (Podcast progress is off by default),
/// then a warning before anything is deleted.
Future<void> showClearPlayData(BuildContext context, WidgetRef ref) async {
  final picked = {PlayData.listening, PlayData.playCounts, PlayData.recent};
  final go = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('清除播放資料'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final k in PlayData.values)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: picked.contains(k),
                onChanged: (v) => setState(() => v == true ? picked.add(k) : picked.remove(k)),
                title: Text(k.label),
                subtitle: Text(k.description),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, picked.isNotEmpty), child: const Text('下一步')),
        ],
      ),
    ),
  );
  if (go != true || !context.mounted) return;
  final names = [for (final k in PlayData.values) if (picked.contains(k)) k.label].join('、');
  if (!await confirmDelete(context,
      title: '清除播放資料？', message: '會清除：$names。\n無法復原。歌曲、播放清單和已按讚的歌曲不受影響。', action: '清除')) {
    return;
  }
  await ref.read(dbProvider).clearPlayData(picked);
  if (context.mounted) toast(context, '已清除$names');
}
