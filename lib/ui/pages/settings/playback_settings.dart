import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';
import '../../../services/desktop_tray.dart';
import '../../../services/equalizer.dart';
import '../../../services/sleep_timer.dart';
import '../../widgets/sleep_timer_sheet.dart';
import '../../widgets/song_font.dart';
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
      if (Platform.isWindows) ...[
        _DbSwitch(
          keyName: 'close_to_tray',
          icon: Icons.minimize,
          title: '關閉視窗時縮到系統匣繼續播放',
          subtitle: '開啟後按 ✕ 會縮到右下角系統匣，音樂繼續播；要結束請在系統匣圖示按右鍵 → 結束。關閉時按 ✕ 就是結束',
          onChanged: DesktopTray.setEnabled,
        ),
        const _DbSwitch(
          keyName: 'start_with_windows',
          icon: Icons.power_settings_new,
          title: '開機時自動啟動',
          subtitle: '登入 Windows 時打開 OuOPlayer（系統匣選項開著時，直接縮在系統匣）',
          onChanged: DesktopTray.setStartWithWindows,
        ),
        const SettingTile(
          leading: Icon(Icons.font_download_outlined),
          title: Text('歌名字體'),
          subtitle: Text('播放條、右側欄、佇列和播放頁的歌名與歌手'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
          child: SegmentedButton<SongFont>(
            showSelectedIcon: false,
            segments: [for (final f in SongFont.values) ButtonSegment(value: f, label: Text(f.label))],
            selected: {ref.watch(songFontProvider)},
            onSelectionChanged: (v) => ref.read(songFontProvider.notifier).set(v.first),
          ),
        ),
      ],
      SettingTile(
        action: '開啟',
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
      SettingSwitch(
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
      SettingSwitch(
        secondary: const Icon(Icons.shuffle),
        title: const Text('隨機播放時，沒播過的歌優先'),
        subtitle: const Text('聽滿 30 秒才算播過，播過的歌排在後面'),
        value: s.unplayedFirst,
        onChanged: n.setUnplayedFirst,
      ),
      SettingSwitch(
        secondary: const Icon(Icons.all_inclusive),
        title: const Text('佇列播完後繼續播放'),
        subtitle: const Text('從音樂庫隨機接著播放'),
        value: s.continueAfterQueue,
        onChanged: n.setContinueAfterQueue,
      ),
      SettingTile(
        action: '設定',
        leading: const Icon(Icons.bedtime_outlined),
        title: const Text('睡眠計時器'),
        subtitle: Text(sleepTimerLabel(ref.watch(sleepTimerProvider))),
        onTap: () => showSleepTimerSheet(context, ref),
      ),
    ]);
  }
}

/// A switch kept straight in the settings table (Windows window options).
class _DbSwitch extends ConsumerStatefulWidget {
  const _DbSwitch({required this.keyName, required this.icon, required this.title, required this.subtitle, required this.onChanged});
  final String keyName;
  final IconData icon;
  final String title;
  final String subtitle;
  final Future<void> Function(bool) onChanged;

  @override
  ConsumerState<_DbSwitch> createState() => _DbSwitchState();
}

class _DbSwitchState extends ConsumerState<_DbSwitch> {
  bool _on = false;

  @override
  void initState() {
    super.initState();
    ref.read(dbProvider).allSettings().then((s) {
      if (mounted) setState(() => _on = s[widget.keyName] == 'true');
    });
  }

  @override
  Widget build(BuildContext context) => SettingSwitch(
        secondary: Icon(widget.icon),
        title: Text(widget.title),
        subtitle: Text(widget.subtitle),
        value: _on,
        onChanged: (v) async {
          setState(() => _on = v);
          await ref.read(dbProvider).setSetting(widget.keyName, '$v');
          await widget.onChanged(v);
        },
      );
}
