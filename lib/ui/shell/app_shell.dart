import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../../theme/app_theme.dart';
import '../pages/collection_page.dart';
import '../pages/downloads_page.dart';
import '../pages/home_page.dart';
import '../pages/library_page.dart';
import '../pages/podcasts_page.dart';
import '../pages/search_page.dart';
import '../pages/settings_page.dart';
import '../widgets/art_image.dart';
import '../widgets/dialogs.dart';
import '../widgets/mini_player.dart';

const _tabs = [
  (icon: Icons.home_outlined, active: Icons.home, label: '首頁'),
  (icon: Icons.search, active: Icons.search, label: '搜尋'),
  (icon: Icons.library_music_outlined, active: Icons.library_music, label: '音樂庫'),
  (icon: Icons.download_outlined, active: Icons.download, label: '下載'),
];

Widget _tabPage(int i) => switch (i) {
      0 => const HomePage(),
      1 => const SearchPage(),
      2 => const LibraryPage(),
      _ => const DownloadsPage(),
    };

/// Responsive shell: bottom navigation on phones, Spotify-desktop layout
/// (sidebar + content + bottom player bar) on wide windows.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  final _navKey = GlobalKey<NavigatorState>();

  void _go(int i) {
    // Re-selecting the current tab returns to its root page, like Spotify.
    if (i == ref.read(tabProvider)) {
      _navKey.currentState?.popUntil((r) => r.isFirst);
      return;
    }
    ref.read(tabProvider.notifier).set(i);
  }

  void _push(Widget w) => _navKey.currentState?.push(MaterialPageRoute(builder: (_) => w));

  @override
  Widget build(BuildContext context) {
    ref.listen(tabProvider, (_, i) {
      _navKey.currentState?.pushAndRemoveUntil(
        PageRouteBuilder(pageBuilder: (_, __, ___) => _tabPage(i), transitionDuration: Duration.zero),
        (_) => false,
      );
    });
    final tab = ref.watch(tabProvider);
    final wide = MediaQuery.sizeOf(context).width >= 720;

    final content = PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final nav = _navKey.currentState;
        if (nav != null && nav.canPop()) {
          nav.pop();
        } else if (tab != 0) {
          _go(0);
        }
      },
      // Pages in here sit above the player bar; toasts use this to move up.
      child: PlayerBarScope(
        child: Navigator(
          key: _navKey,
          onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => _tabPage(tab)),
        ),
      ),
    );

    if (!wide) {
      return Scaffold(
        body: Column(children: [
          Expanded(child: content),
          const MiniPlayer(),
        ]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          height: 64,
          onDestinationSelected: _go,
          destinations: [
            for (final t in _tabs) NavigationDestination(icon: Icon(t.icon), selectedIcon: Icon(t.active), label: t.label),
          ],
        ),
      );
    }

    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Theme.of(context).brightness == Brightness.dark ? Colors.black : cs.surfaceContainer,
      body: Column(children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(width: 280, child: _Sidebar(tab: tab, onTab: _go, onPush: _push)),
              const SizedBox(width: 8),
              Expanded(
                child: ClipRRect(borderRadius: BorderRadius.circular(8), child: content),
              ),
            ]),
          ),
        ),
        const DesktopPlayerBar(),
      ]),
    );
  }
}

class _Sidebar extends ConsumerWidget {
  const _Sidebar({required this.tab, required this.onTab, required this.onPush});
  final int tab;
  final void Function(int) onTab;
  final void Function(Widget) onPush;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final playlists = ref.watch(playlistsProvider).value ?? const [];
    final folders = ref.watch(libraryFoldersProvider).value ?? const [];
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Widget panel(Widget child) => Container(
          decoration: BoxDecoration(color: cs.surface, borderRadius: BorderRadius.circular(8)),
          child: child,
        );
    return Column(children: [
      panel(Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 8, 4),
          child: Row(children: [
            const Icon(Icons.graphic_eq, color: AppColors.accent, size: 28),
            const SizedBox(width: 8),
            const Expanded(child: Text('OuOPlayer', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900))),
            IconButton(
              tooltip: isDark ? '切換為淺色' : '切換為深色',
              icon: Icon(isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
              onPressed: () => ref.read(settingsProvider.notifier).setTheme(isDark ? ThemeMode.light : ThemeMode.dark),
            ),
          ]),
        ),
        for (var i = 0; i < _tabs.length; i++)
          ListTile(
            leading: Icon(tab == i ? _tabs[i].active : _tabs[i].icon, color: tab == i ? cs.onSurface : cs.onSurfaceVariant),
            title: Text(_tabs[i].label,
                style: TextStyle(fontWeight: FontWeight.bold, color: tab == i ? cs.onSurface : cs.onSurfaceVariant)),
            onTap: () => onTab(i),
          ),
        ListTile(
          leading: Icon(Icons.settings_outlined, color: cs.onSurfaceVariant),
          title: Text('設定', style: TextStyle(fontWeight: FontWeight.bold, color: cs.onSurfaceVariant)),
          onTap: () => onPush(const SettingsPage()),
        ),
      ])),
      const SizedBox(height: 8),
      Expanded(
        child: panel(ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
          ListTile(
            leading: Icon(Icons.library_music, color: cs.onSurfaceVariant),
            title: Text('你的音樂庫', style: TextStyle(fontWeight: FontWeight.bold, color: cs.onSurfaceVariant)),
            onTap: () => onTab(2),
          ),
          ListTile(
            leading: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                gradient: const LinearGradient(colors: [Color(0xFF3A2FD8), AppColors.accent]),
              ),
              child: const Icon(Icons.favorite, color: Colors.white, size: 20),
            ),
            title: const Text('已按讚的歌曲'),
            onTap: () => onPush(CollectionPage.favorites()),
          ),
          for (final f in folders)
            ListTile(
              leading: folderIcon(context, f, 44),
              title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${f.path == null ? '本機' : '資料夾'} • ${f.count} 首', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              onTap: () => onPush(CollectionPage.folder(f.path, f.name)),
            ),
          ListTile(
            leading: ArtImage(null, size: 44, icon: Icons.podcasts),
            title: const Text('Podcast'),
            onTap: () => onPush(const PodcastsPage()),
          ),
          for (final pl in playlists)
            ListTile(
              leading: ArtImage(pl.art, size: 44, icon: Icons.queue_music),
              title: Text(pl.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('播放清單 • ${pl.count} 首', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              onTap: () => onPush(CollectionPage.playlist(pl.id, pl.name)),
            ),
        ])),
      ),
    ]);
  }
}
