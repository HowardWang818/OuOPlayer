import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../../theme/app_theme.dart';
import '../widgets/art_image.dart';
import '../widgets/cards.dart';
import '../widgets/dialogs.dart';
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

    // Shortcuts: pinned ones first (long press to pin / remove), then liked
    // songs, Podcast, playlists and recent albums; 8 at most.
    final settings = ref.watch(settingsProvider);
    final all = <String, (Widget, String, VoidCallback)>{
      'liked': (
        Container(
          decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF3A2FD8), AppColors.accent])),
          child: const Icon(Icons.favorite, color: Colors.white),
        ),
        '已按讚的歌曲',
        () => push(CollectionPage.favorites()),
      ),
      'podcast': (
        Container(color: AppColors.accent.withValues(alpha: 0.25), child: const Icon(Icons.podcasts, color: AppColors.accent)),
        'Podcast',
        () => push(const PodcastsPage()),
      ),
      for (final pl in playlists)
        'playlist:${pl.id}': (
          ArtImage(pl.art, size: 56, radius: 0, icon: Icons.queue_music),
          pl.name,
          () => push(CollectionPage.playlist(pl.id, pl.name)),
        ),
      for (final a in albums) 'album:${a.name}': (ArtImage(a.art, size: 56, radius: 0), a.name, () => push(CollectionPage.album(a.name))),
    };
    // Liked songs and Podcast are always there (Podcast has no other way in on the phone).
    const fixed = {'liked', 'podcast'};
    bool hidden(String k) => !fixed.contains(k) && settings.homeHidden.contains(k);
    final shown = <String>[
      for (final k in settings.homePinned)
        if (all.containsKey(k) && !hidden(k)) k,
    ];
    final defaults = [
      'liked',
      'podcast',
      ...playlists.map((p) => 'playlist:${p.id}').where((k) => !hidden(k)).take(4),
      ...albums.map((a) => 'album:${a.name}'),
    ];
    for (final k in defaults) {
      if (shown.length >= 8) break;
      if (!shown.contains(k) && !hidden(k)) shown.add(k);
    }
    final quick = <Widget>[
      for (final k in shown)
        QuickTile(
          leading: all[k]!.$1,
          title: all[k]!.$2,
          onTap: all[k]!.$3,
          pinned: settings.homePinned.contains(k),
          onLongPress: fixed.contains(k) ? null : () => _shortcutMenu(context, ref, k, all[k]!.$2),
        ),
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

/// Long press on a home shortcut: pin it first, or take it off the home page.
Future<void> _shortcutMenu(BuildContext context, WidgetRef ref, String key, String title) async {
  final n = ref.read(settingsProvider.notifier);
  final pinned = ref.read(settingsProvider).homePinned.contains(key);
  final choice = await showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold))),
        ListTile(
          leading: Icon(pinned ? Icons.push_pin_outlined : Icons.push_pin),
          title: Text(pinned ? '取消釘選' : '釘選'),
          subtitle: Text(pinned ? '' : '固定排在首頁最前面'),
          onTap: () => Navigator.pop(ctx, 'pin'),
        ),
        ListTile(
          leading: const Icon(Icons.remove_circle_outline),
          title: const Text('從首頁移除'),
          subtitle: const Text('之後可以在「設定 → 音樂庫」還原'),
          onTap: () => Navigator.pop(ctx, 'hide'),
        ),
      ]),
    ),
  );
  if (!context.mounted) return;
  if (choice == 'pin') {
    n.setHomePinned(key, !pinned);
    toast(context, pinned ? '已取消釘選' : '已釘選「$title」');
  } else if (choice == 'hide') {
    if (!await confirmDelete(context, title: '從首頁移除「$title」？', message: '只是不顯示在首頁，不會刪除任何東西。', action: '移除')) return;
    n.setHomeHidden(key, true);
    if (context.mounted) toast(context, '已從首頁移除');
  }
}
