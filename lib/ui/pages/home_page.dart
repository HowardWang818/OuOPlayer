import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../../theme/app_theme.dart';
import '../widgets/art_image.dart';
import '../widgets/cards.dart';
import 'collection_page.dart';
import 'podcasts_page.dart';
import 'settings_page.dart';
import 'stats_page.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 5) return '夜深了';
    if (h < 12) return '早安';
    if (h < 18) return '午安';
    return '晚安';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(recentlyPlayedProvider).value ?? const [];
    final albums = ref.watch(recentAlbumsProvider).value ?? const [];
    final playlists = ref.watch(playlistsProvider).value ?? const [];
    final tracks = ref.watch(tracksProvider);
    final scan = ref.watch(scanProgressProvider).value;
    final handler = ref.read(audioHandlerProvider);
    void push(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    final width = MediaQuery.sizeOf(context).width;
    final cols = width > 1300 ? 4 : (width > 720 ? 3 : 2);

    final quick = <Widget>[
      QuickTile(
        leading: Container(
          decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF3A2FD8), AppColors.accent])),
          child: const Icon(Icons.favorite, color: Colors.white),
        ),
        title: '已按讚的歌曲',
        onTap: () => push(CollectionPage.favorites()),
      ),
      QuickTile(
        leading: Container(color: AppColors.accent.withValues(alpha: 0.25), child: const Icon(Icons.podcasts, color: AppColors.accent)),
        title: 'Podcast',
        onTap: () => push(const PodcastsPage()),
      ),
      for (final pl in playlists.take(4))
        QuickTile(
          leading: ArtImage(pl.art, size: 56, radius: 0, icon: Icons.queue_music),
          title: pl.name,
          onTap: () => push(CollectionPage.playlist(pl.id, pl.name)),
        ),
      for (final a in albums.take(6 - playlists.take(4).length))
        QuickTile(leading: ArtImage(a.art, size: 56, radius: 0), title: a.name, onTap: () => push(CollectionPage.album(a.name))),
    ];

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.center,
            colors: [AppColors.accent.withValues(alpha: 0.22), Theme.of(context).scaffoldBackgroundColor],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
              child: Row(children: [
                Expanded(child: Text(_greeting(), style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold))),
                // Light / dark: the moon while dark, the sun while light.
                Builder(builder: (context) {
                  final dark = Theme.of(context).brightness == Brightness.dark;
                  return IconButton(
                    icon: Icon(dark ? Icons.dark_mode_outlined : Icons.light_mode_outlined),
                    tooltip: dark ? '切換成淺色' : '切換成深色',
                    onPressed: () => ref.read(settingsProvider.notifier).setTheme(dark ? ThemeMode.light : ThemeMode.dark),
                  );
                }),
                IconButton(icon: const Icon(Icons.insights_outlined), tooltip: '收聽統計', onPressed: () => push(const StatsPage())),
                IconButton(icon: const Icon(Icons.settings_outlined), tooltip: '設定', onPressed: () => push(const SettingsPage())),
              ]),
            ),
            if (scan != null && scan.running)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(scan.total == 0 ? '正在搜尋音樂檔案…' : '正在讀取標籤 ${scan.done}/${scan.total}'),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(value: scan.total == 0 ? null : scan.done / scan.total),
                ]),
              ),
            if ((tracks.value ?? const []).isEmpty && !(scan?.running ?? false))
              Card(
                margin: const EdgeInsets.all(16),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('音樂庫是空的', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    const Text('掃描本機音樂資料夾，或到「下載」分頁貼上網址下載音樂。'),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      icon: const Icon(Icons.search),
                      label: const Text('掃描音樂資料夾'),
                      onPressed: () => rescanLibrary(context, ref),
                    ),
                  ]),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: LayoutBuilder(
                builder: (context, c) => GridView.count(
                  crossAxisCount: cols,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: ((c.maxWidth - 8 * (cols - 1)) / cols) / 56,
                  children: quick,
                ),
              ),
            ),
            Shelf(title: '最近播放', children: [
              for (var i = 0; i < recent.length; i++)
                CoverCard(
                  art: recent[i].art,
                  title: recent[i].title,
                  subtitle: recent[i].artist,
                  icon: Icons.music_note,
                  onTap: () => handler.playTracks(recent, index: i),
                ),
            ]),
            Shelf(title: '最近加入的專輯', children: [
              for (final a in albums)
                CoverCard(art: a.art, title: a.name, subtitle: a.artist, onTap: () => push(CollectionPage.album(a.name))),
            ]),
          ]),
        ),
      ),
    );
  }
}
