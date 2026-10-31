import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';
import 'section_page.dart';

/// Podcast: speed, skipping silence, seek step.
class PodcastSettingsPage extends ConsumerWidget {
  const PodcastSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return SettingsSectionPage(title: 'Podcast', children: [
      ListTile(
        leading: const Icon(Icons.speed),
        title: const Text('播放速度'),
        subtitle: const Text('音樂一律以原速播放'),
        trailing: DropdownButton<double>(
          value: s.podcastSpeed,
          underline: const SizedBox(),
          items: [for (final v in podcastSpeeds) DropdownMenuItem(value: v, child: Text('${v}x'))],
          onChanged: (v) => n.setPodcastSpeed(v!),
        ),
      ),
      if (Platform.isAndroid)
        SettingSwitch(
          secondary: const Icon(Icons.content_cut),
          title: const Text('跳過靜音'),
          subtitle: const Text('自動略過沒有聲音的段落'),
          value: s.podcastSkipSilence,
          onChanged: n.setPodcastSkipSilence,
        ),
      const ListTile(
        leading: Icon(Icons.fast_forward_outlined),
        title: Text('快轉 / 倒轉秒數'),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
        child: SegmentedButton<int>(
          segments: [for (final v in seekSecondOptions) ButtonSegment(value: v, label: Text('$v 秒'))],
          selected: {s.seekSeconds},
          onSelectionChanged: (v) => n.setSeekSeconds(v.first),
        ),
      ),
    ]);
  }
}
