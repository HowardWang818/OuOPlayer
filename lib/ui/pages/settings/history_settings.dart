import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';
import '../../widgets/clear_play_data.dart';
import '../stats_page.dart';
import 'section_page.dart';

/// 播放紀錄與統計.
class HistorySettingsPage extends ConsumerWidget {
  const HistorySettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return SettingsSectionPage(title: '播放紀錄與統計', children: [
      SwitchListTile(
        secondary: const Icon(Icons.history),
        title: const Text('記錄播放紀錄'),
        subtitle: Text(s.recordPlays
            ? '最近播放、播放次數（智慧播放清單）和收聽統計'
            : '已關閉：不再記錄。以前的紀錄還在，可以用下面的按鈕清除。Podcast 收聽進度照常記錄'),
        value: s.recordPlays,
        onChanged: n.setRecordPlays,
      ),
      ListTile(
        leading: const Icon(Icons.insights_outlined),
        title: const Text('收聽統計'),
        subtitle: const Text('最常聽的歌、歌手、收聽時間和年度回顧'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const StatsPage())),
      ),
      ListTile(
        leading: const Icon(Icons.delete_sweep_outlined),
        title: const Text('清除播放資料'),
        subtitle: const Text('可以選擇清除收聽統計、播放次數、最近播放或 Podcast 進度'),
        onTap: () => showClearPlayData(context, ref),
      ),
    ]);
  }
}
