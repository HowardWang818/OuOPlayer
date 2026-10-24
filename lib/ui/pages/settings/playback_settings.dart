import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';
import '../../../services/equalizer.dart';
import '../../../services/sleep_timer.dart';
import '../../widgets/sleep_timer_sheet.dart';
import '../equalizer_page.dart';
import 'section_page.dart';

/// 播放: equalizer, fades, loudness, what plays after the queue, sleep timer.
class PlaybackSettingsPage extends ConsumerWidget {
  const PlaybackSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return SettingsSectionPage(title: '播放', children: [
      ListTile(
        leading: const Icon(Icons.graphic_eq),
        title: const Text('等化器'),
        subtitle: Text(s.eqEnabled ? '已開啟：${EqPreset.byName(s.eqPreset).label}' : '關閉'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EqualizerPage())),
      ),
      ListTile(
        leading: const Icon(Icons.blur_linear),
        title: const Text('播放／暫停淡入淡出'),
        subtitle: Text(s.fadeMs == 0 ? '關閉' : '${s.fadeMs / 1000} 秒（換歌時不淡出）'),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
        child: SegmentedButton<int>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 0, label: Text('關')),
            ButtonSegment(value: 300, label: Text('0.3')),
            ButtonSegment(value: 500, label: Text('0.5')),
            ButtonSegment(value: 1000, label: Text('1')),
            ButtonSegment(value: 2000, label: Text('2')),
          ],
          selected: {s.fadeMs},
          onSelectionChanged: (v) => n.setFadeMs(v.first),
        ),
      ),
      SwitchListTile(
        secondary: const Icon(Icons.equalizer),
        title: const Text('音量標準化'),
        subtitle: const Text('讓每首歌聽起來一樣大聲'),
        value: s.normalizeVolume,
        onChanged: n.setNormalizeVolume,
      ),
      if (s.normalizeVolume)
        Padding(
          padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
          child: SegmentedButton<NormalizeLevel>(
            segments: [for (final l in NormalizeLevel.values) ButtonSegment(value: l, label: Text(l.label))],
            selected: {s.normalizeLevel},
            onSelectionChanged: (v) => n.setNormalizeLevel(v.first),
          ),
        ),
      SwitchListTile(
        secondary: const Icon(Icons.all_inclusive),
        title: const Text('佇列播完後繼續播放'),
        subtitle: const Text('從音樂庫隨機接著播放'),
        value: s.continueAfterQueue,
        onChanged: n.setContinueAfterQueue,
      ),
      ListTile(
        leading: const Icon(Icons.bedtime_outlined),
        title: const Text('睡眠計時器'),
        subtitle: Text(sleepTimerLabel(ref.watch(sleepTimerProvider))),
        onTap: () => showSleepTimerSheet(context, ref),
      ),
    ]);
  }
}
