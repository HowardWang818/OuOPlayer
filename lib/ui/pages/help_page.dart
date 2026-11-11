import 'package:flutter/material.dart';

import '../widgets/download_actions.dart' show downloadTerms;
import '../widgets/links.dart';
import 'onboarding_page.dart';

/// Help (the round ? on 下載): copying links, converting playlists with
/// Soundiiz, and the first-run guide again.
class HelpPage extends StatelessWidget {
  const HelpPage({super.key});

  static const sections = <(IconData, String, List<String>)>[
    (Icons.search, '搜尋並下載', [
      '在「搜尋」頁切換到「網路」。',
      '輸入歌名，點一下試聽，點下載按鈕下載。',
    ]),
    (Icons.link, '貼上連結下載', [
      '在 YouTube 或 YouTube Music 開啟歌曲或播放清單。',
      '點「分享」→「複製連結」。',
      '回到 OuOPlayer 的「下載」頁貼上。',
    ]),
    (Icons.swap_horiz, '轉換 Spotify 等歌單', [
      '前往 soundiiz.com 並登入。',
      '選擇「Transfer」，來源選 Spotify 等平台，目的地選 YouTube Music。',
      '轉換完成後，在 YouTube Music 開啟該播放清單，複製連結並貼到「下載」頁。',
    ]),
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Help')),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
        for (final (icon, title, steps) in sections) ...[
          const SizedBox(height: 16),
          Row(children: [
            Icon(icon, color: cs.primary),
            const SizedBox(width: 10),
            Text(title, style: t.titleMedium),
          ]),
          const SizedBox(height: 8),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(left: 34, bottom: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 20, child: Text('${i + 1}.', style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant))),
                Expanded(child: Text(steps[i], style: t.bodyMedium?.copyWith(height: 1.5))),
              ]),
            ),
        ],
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(left: 34),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => openExternal(context, 'https://soundiiz.com'),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('soundiiz.com'),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(downloadTerms, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        const SizedBox(height: 24),
        FilledButton.tonalIcon(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const OnboardingPage())),
          icon: const Icon(Icons.play_circle_outline),
          label: const Text('第一次使用說明'),
        ),
      ]),
    );
  }
}
