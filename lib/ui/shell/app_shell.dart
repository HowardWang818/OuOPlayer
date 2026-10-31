import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../../services/window_state.dart';
import '../../theme/app_theme.dart';
import '../pages/collection_page.dart';
import '../pages/downloads_page.dart';
import '../pages/folder_page.dart';
import '../pages/home_page.dart';
import '../pages/library_page.dart';
import '../pages/podcasts_page.dart';
import '../pages/search_page.dart';
import '../pages/settings/shortcut_settings.dart';
import '../pages/settings_page.dart';
import '../widgets/art_image.dart';
import '../widgets/dialogs.dart';
import '../widgets/hover.dart';
import '../widgets/mini_player.dart';
import '../widgets/now_playing_panel.dart';
import '../widgets/theme_button.dart';
import '../widgets/track_selection.dart';
import 'app_shortcuts.dart';

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
  void initState() {
    super.initState();
    if (Platform.isWindows) FocusManager.instance.addEarlyKeyEventHandler(_onKey);
  }

  @override
  void dispose() {
    if (Platform.isWindows) FocusManager.instance.removeEarlyKeyEventHandler(_onKey);
    super.dispose();
  }

  /// The page a shortcut opened, and whether the player was open then: the
  /// same shortcut goes back there.
  ({AppAction action, Route<dynamic> page, bool player})? _opened;

  /// 快捷鍵一覽 is open: its key closes it.
  bool _helpOpen = false;

  // The queue shortcut: the player it last acted on, whether it opened that
  // player itself, and whether it hid the lyrics there.
  Route<dynamic>? _queuePlayer;
  bool _queueOpened = false;
  bool _queueHidLyrics = false;

  Route<dynamic>? _top(NavigatorState nav) {
    Route<dynamic>? top;
    nav.popUntil((r) {
      top = r;
      return true;
    });
    return top;
  }

  /// Windows: the keys of 設定 → 快捷鍵. Not while typing or in a dialog
  /// (Flutter closes dialogs itself on Esc). Runs ahead of the focus tree: a
  /// key used here doesn't also press the focused button.
  KeyEventResult _onKey(KeyEvent e) {
    if (e is KeyUpEvent || !mounted) return KeyEventResult.ignored;
    final combo = KeyCombo.ofEvent(e);
    final action = actionFor(ref.read(shortcutsProvider), combo);
    if (!combo.isEscape && action == null) return KeyEventResult.ignored;
    final root = Navigator.of(context, rootNavigator: true);
    if (_top(root) is PopupRoute) {
      if (action != AppAction.help || !_helpOpen) return KeyEventResult.ignored;
      if (e is KeyDownEvent) root.pop();
      return KeyEventResult.handled;
    }
    final focus = FocusManager.instance.primaryFocus;
    final typing = focus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;
    if (combo.isEscape) {
      if (e is KeyDownEvent) typing ? focus!.unfocus() : _back(root);
      return KeyEventResult.handled;
    }
    // Ctrl+F also closes the box being typed in.
    if (typing && action != AppAction.filter) return KeyEventResult.ignored;
    if (e is KeyDownEvent || action!.repeats) _run(action!, root);
    return KeyEventResult.handled;
  }

  /// Esc: what the back button does.
  Future<void> _back(NavigatorState root) async {
    if (ModalRoute.of(context)?.isCurrent == false) {
      await root.maybePop();
      return;
    }
    final popped = await _navKey.currentState?.maybePop() ?? false;
    if (!popped && mounted && ref.read(tabProvider) != 0) _go(0);
  }

  /// Opens [page] above where we are, or goes back from it. Above, not by
  /// switching tabs, which would lose the pages of the tab we came from.
  void _togglePage(AppAction action, Widget page, NavigatorState root) {
    final nav = _navKey.currentState;
    if (nav == null) return;
    final shell = ModalRoute.of(context);
    final covered = shell?.isCurrent == false;
    final opened = _opened;
    if (opened != null && opened.action == action && opened.page.isCurrent) {
      if (covered) {
        root.popUntil((r) => r == shell);
        return;
      }
      _opened = null;
      nav.pop();
      if (opened.player) openNowPlaying(context);
      return;
    }
    if (covered) root.popUntil((r) => r == shell);
    final route = MaterialPageRoute<void>(builder: (_) => page);
    _opened = (action: action, page: route, player: covered);
    nav.push(route);
  }

  /// On the tab's own first page already: nothing to open.
  bool _onTabRoot(int tab) => ref.read(tabProvider) == tab && !(_navKey.currentState?.canPop() ?? true);

  void _toggleQueue(NavigatorState root, bool covered) {
    final lyrics = ref.read(showLyricsProvider.notifier);
    if (!covered) {
      _queueHidLyrics = ref.read(showLyricsProvider);
      if (_queueHidLyrics) lyrics.toggle();
      openNowPlaying(context);
      _queuePlayer = _top(root);
      _queueOpened = true;
    } else if (ref.read(showLyricsProvider)) {
      lyrics.toggle();
      _queuePlayer = _top(root);
      _queueOpened = false;
      _queueHidLyrics = true;
    } else if (_queueHidLyrics && _queuePlayer == _top(root)) {
      // Back as it was: the lyrics, and the page under the player if that's
      // where the key was pressed.
      lyrics.toggle();
      _queueHidLyrics = false;
      if (_queueOpened) root.pop();
    } else {
      root.pop();
    }
  }

  void _run(AppAction action, NavigatorState root) {
    final handler = ref.read(audioHandlerProvider);
    final route = ModalRoute.of(context);
    // The full player (or a picture) is open above the shell.
    final covered = route?.isCurrent == false;

    void volume(int steps) => handler.setUserVolume(((handler.userVolume.value * 20).round() + steps) / 20);

    switch (action) {
      case AppAction.playPause || AppAction.playPause2:
        handler.player.playing ? handler.pause() : handler.play();
      case AppAction.previous:
        handler.skipToPrevious();
      case AppAction.next:
        handler.skipToNext();
      case AppAction.back:
        handler.rewind();
      case AppAction.forward:
        handler.fastForward();
      case AppAction.volumeUp:
        volume(1);
      case AppAction.volumeDown:
        volume(-1);
      case AppAction.mute:
        handler.toggleMute();
      case AppAction.lyrics:
        covered ? ref.read(showLyricsProvider.notifier).toggle() : ref.read(desktopLayoutProvider.notifier).toggleLyrics();
      case AppAction.search:
        final opened = _opened?.action == AppAction.search && _opened!.page.isCurrent;
        if (!opened) searchFocusWanted.value = true;
        if (_onTabRoot(1)) {
          if (covered) root.popUntil((r) => r == route);
        } else {
          _togglePage(action, const SearchPage(), root);
        }
      case AppAction.filter:
        if (!covered) TrackSelectionScope.filterInFront();
      case AppAction.selectAll:
        if (!covered) TrackSelectionScope.selectAllInFront();
      case AppAction.nowPlaying:
        covered ? root.pop() : openNowPlaying(context);
      case AppAction.queue:
        _toggleQueue(root, covered);
      case AppAction.home:
        if (_onTabRoot(0)) {
          if (covered) root.popUntil((r) => r == route);
        } else {
          _togglePage(action, const HomePage(), root);
        }
      case AppAction.settings:
        _togglePage(action, const SettingsPage(), root);
      case AppAction.help:
        _helpOpen = true;
        showShortcutHelp(context, ref.read(shortcutsProvider)).whenComplete(() => _helpOpen = false);
    }
  }

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
        // The player (or another page) opened above the shell closes first:
        // back sometimes reaches the shell while it's still covered.
        // (The player, a picture viewer…: anything on the root navigator.)
        final root = Navigator.of(context, rootNavigator: true);
        final route = ModalRoute.of(context);
        if (root.canPop() && (route == null || !route.isCurrent)) {
          root.pop();
          return;
        }
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
    final desktop = Platform.isWindows;
    final layout = ref.watch(desktopLayoutProvider);
    final notifier = ref.read(desktopLayoutProvider.notifier);
    return Scaffold(
      backgroundColor: Theme.of(context).brightness == Brightness.dark ? Colors.black : cs.surfaceContainer,
      body: Column(children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: LayoutBuilder(builder: (context, c) {
              const gap = DesktopLayout.gap, centerMin = DesktopLayout.centerMin;
              if (!desktop) {
                return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SizedBox(width: 280, child: _Sidebar(tab: tab, onTab: _go, onPush: _push)),
                  const SizedBox(width: gap),
                  Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(8), child: content)),
                ]);
              }
              final total = c.maxWidth;
              // The right panel gives way first when the window is too narrow.
              final left = min(layout.left, max(DesktopLayout.leftMin, total - gap - centerMin));
              final showRight = total - left - 2 * gap - layout.right >= centerMin;
              final right = layout.right;
              return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(
                  width: left,
                  child: _Sidebar(tab: tab, onTab: _go, onPush: _push, navHeight: layout.nav),
                ),
                PanelDivider(
                  value: left,
                  onDrag: (at) {
                    final room = total - centerMin - (showRight ? right + 2 * gap : gap);
                    notifier.setLeft(at.clamp(DesktopLayout.leftMin, max(DesktopLayout.leftMin, min(DesktopLayout.leftMax, room))));
                  },
                  onEnd: notifier.save,
                ),
                Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(8), child: content)),
                if (showRight) ...[
                  PanelDivider(
                    value: right,
                    reversed: true,
                    onDrag: (at) {
                      final room = total - centerMin - left - 2 * gap;
                      notifier.setRight(at.clamp(DesktopLayout.rightMin, max(DesktopLayout.rightMin, min(DesktopLayout.rightMax, room))));
                    },
                    onEnd: notifier.save,
                  ),
                  SizedBox(width: right, child: NowPlayingPanel(push: _push)),
                ],
              ]);
            }),
          ),
        ),
        const DesktopPlayerBar(),
      ]),
    );
  }
}

/// A row of the sidebar: no background under the mouse; its text and icon
/// take the accent colour there and on the page it's on.
class _SideTile extends StatelessWidget {
  const _SideTile({required this.leading, required this.title, this.subtitle, required this.onTap, this.bold = false, this.selected = false});
  final Widget leading;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  /// A heading row (首頁, 搜尋…): grey until chosen or under the mouse.
  final bool bold;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Hover(builder: (context, on) {
      final lit = on || selected;
      final color = lit ? cs.primary : (bold ? cs.onSurfaceVariant : cs.onSurface);
      return ListTile(
        hoverColor: Colors.transparent,
        iconColor: lit ? cs.primary : cs.onSurfaceVariant,
        leading: leading,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontWeight: bold ? FontWeight.bold : null)),
        subtitle: subtitle == null ? null : Text(subtitle!, style: TextStyle(fontSize: 12, color: lit ? cs.primary : cs.onSurfaceVariant)),
        onTap: onTap,
      );
    });
  }
}

class _Sidebar extends ConsumerWidget {
  const _Sidebar({required this.tab, required this.onTab, required this.onPush, this.navHeight});
  final int tab;
  final void Function(int) onTab;
  final void Function(Widget) onPush;

  /// Windows: the height of the top block, set with the divider below it.
  final double? navHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final playlists = ref.watch(topLevelPlaylistsProvider).value ?? const [];
    final playlistFolders = ref.watch(playlistFoldersProvider).value ?? const [];
    final folders = ref.watch(libraryFoldersProvider).value ?? const [];
    Widget panel(Widget child) => Container(
          decoration: BoxDecoration(color: cs.surface, borderRadius: BorderRadius.circular(8)),
          child: child,
        );
    final nav = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
        child: Row(children: [
          Icon(Icons.graphic_eq, color: cs.primary, size: 28),
          const SizedBox(width: 8),
          const Expanded(child: Text('OuOPlayer', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900))),
          const ThemeButton(),
        ]),
      ),
      for (var i = 0; i < _tabs.length; i++)
        _SideTile(leading: Icon(tab == i ? _tabs[i].active : _tabs[i].icon), title: _tabs[i].label, bold: true, selected: tab == i, onTap: () => onTab(i)),
      _SideTile(leading: const Icon(Icons.settings_outlined), title: '設定', bold: true, onTap: () => onPush(const SettingsPage())),
    ];
    final library = Expanded(
      child: panel(ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
        _SideTile(leading: const Icon(Icons.library_music), title: '你的音樂庫', bold: true, onTap: () => onTab(2)),
        _SideTile(
          leading: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              gradient: const LinearGradient(colors: [Color(0xFF3A2FD8), AppColors.accent]),
            ),
            child: const Icon(Icons.favorite, color: Colors.white, size: 20),
          ),
          title: '已按讚的歌曲',
          onTap: () => onPush(CollectionPage.favorites()),
        ),
        for (final f in folders)
          _SideTile(
            leading: folderIcon(context, f, 44),
            title: f.name,
            subtitle: '${f.path == null ? '本機' : '資料夾'} • ${f.count} 首',
            onTap: () => onPush(CollectionPage.folder(f.path, f.name)),
          ),
        _SideTile(leading: ArtImage(null, size: 44, icon: Icons.podcasts), title: 'Podcast', onTap: () => onPush(const PodcastsPage())),
        for (final f in playlistFolders)
          _SideTile(
            leading: PlaylistFolderArt(folder: f, size: 44),
            title: f.name,
            subtitle: '資料夾 • ${f.count} 個',
            onTap: () => onPush(FolderPage(folderId: f.id, name: f.name)),
          ),
        for (final pl in playlists)
          _SideTile(
            leading: ArtImage(pl.art, size: 44, icon: Icons.queue_music),
            title: pl.name,
            subtitle: '播放清單 • ${pl.count} 首',
            onTap: () => onPush(CollectionPage.playlist(pl.id, pl.name)),
          ),
      ])),
    );
    final height = navHeight;
    if (height == null) {
      return Column(children: [panel(Column(children: nav)), const SizedBox(height: DesktopLayout.gap), library]);
    }
    return LayoutBuilder(builder: (context, c) {
      final most = max(DesktopLayout.navMin, c.maxHeight - DesktopLayout.navMin - DesktopLayout.gap);
      final top = height.clamp(DesktopLayout.navMin, most);
      final notifier = ref.read(desktopLayoutProvider.notifier);
      return Column(children: [
        SizedBox(height: top, child: panel(ListView(padding: EdgeInsets.zero, children: nav))),
        PanelDivider(vertical: true, value: top, onDrag: (at) => notifier.setNav(at.clamp(DesktopLayout.navMin, most)), onEnd: notifier.save),
        library,
      ]);
    });
  }
}
