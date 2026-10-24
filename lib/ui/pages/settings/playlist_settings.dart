import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/db/database.dart';
import '../../../providers/providers.dart';
import 'section_page.dart';

/// 播放清單: which smart playlists show, and duplicates.
class PlaylistSettingsPage extends ConsumerWidget {
  const PlaylistSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return SettingsSectionPage(title: '播放清單', children: [
      settingsSubheader(context, '顯示智慧播放清單'),
      for (final l in SmartList.values)
        SwitchListTile(
          secondary: const Icon(Icons.auto_awesome_outlined),
          title: Text(l.label),
          subtitle: Text(l.description),
          value: !s.hiddenSmartLists.contains(l.name),
          onChanged: (v) => n.setSmartListShown(l.name, v),
        ),
      settingsSubheader(context, '加入歌曲'),
      SwitchListTile(
        secondary: const Icon(Icons.copy_all_outlined),
        title: const Text('允許歌曲重複'),
        subtitle: const Text('手動加入播放清單時，同一首歌可以加第二次。下載播放清單時不會重複加入。'),
        value: s.allowPlaylistDuplicates,
        onChanged: n.setAllowPlaylistDuplicates,
      ),
    ]);
  }
}
