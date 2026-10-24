import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';
import 'section_page.dart';

/// 歌詞: looking lyrics up, size, keeping the screen on, lyrics in the car.
class LyricsSettingsPage extends ConsumerWidget {
  const LyricsSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return SettingsSectionPage(title: '歌詞', children: [
      SwitchListTile(
        secondary: const Icon(Icons.lyrics_outlined),
        title: const Text('自動上網找歌詞'),
        subtitle: const Text('歌曲檔案和 .lrc 檔都沒有歌詞時，從 LRCLIB 查詢（免費，只會送出歌名、歌手、專輯和長度）'),
        value: s.lyricsOnline,
        onChanged: n.setLyricsOnline,
      ),
      ListTile(
        leading: const Icon(Icons.format_size),
        title: const Text('歌詞字體大小'),
        subtitle: Text('預覽：這是一行歌詞', style: TextStyle(fontSize: 16 * s.lyricsScale, fontWeight: FontWeight.bold)),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(56, 0, 16, 0),
        child: Slider(
          min: 0.8,
          max: 1.6,
          divisions: 8,
          label: '${(s.lyricsScale * 100).round()}%',
          value: s.lyricsScale.clamp(0.8, 1.6),
          onChanged: (v) => n.setLyricsScale(double.parse(v.toStringAsFixed(1))),
        ),
      ),
      if (Platform.isAndroid)
        SwitchListTile(
          secondary: const Icon(Icons.light_mode_outlined),
          title: const Text('顯示歌詞時螢幕保持常亮'),
          value: s.lyricsKeepAwake,
          onChanged: n.setLyricsKeepAwake,
        ),
      SwitchListTile(
        secondary: const Icon(Icons.subtitles_outlined),
        title: const Text('在車上和通知列顯示歌詞'),
        subtitle: const Text('有同步歌詞時，Android Auto、通知列和鎖定畫面的歌手那一行會換成正在唱的歌詞。開車時請注意安全'),
        value: s.lyricsInMetadata,
        onChanged: n.setLyricsInMetadata,
      ),
    ]);
  }
}
