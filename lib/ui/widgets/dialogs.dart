import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../providers/sync_provider.dart' show offerSync;
import 'art_image.dart';

Future<String?> promptText(BuildContext context, {required String title, String hint = '', String initial = '', String ok = '確定'}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text(ok)),
      ],
    ),
  );
}

Future<void> showAddToPlaylist(BuildContext context, WidgetRef ref, List<Track> tracks) async {
  final db = ref.read(dbProvider);
  final allow = ref.read(settingsProvider).allowPlaylistDuplicates;
  final lists = await db.playlists();
  if (!context.mounted) return;
  await showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        ListTile(
          leading: const Icon(Icons.add),
          title: const Text('新增播放清單'),
          onTap: () async {
            Navigator.pop(ctx);
            final name = await promptText(context, title: '為播放清單命名', hint: '我的播放清單 #${lists.length + 1}');
            if (name == null) return;
            final id = await db.createPlaylist(name.isEmpty ? '我的播放清單 #${lists.length + 1}' : name);
            await db.addToPlaylist(id, tracks, allowDuplicates: allow);
            if (context.mounted) _toast(context, '已加入「${name.isEmpty ? '我的播放清單 #${lists.length + 1}' : name}」');
            if (context.mounted) await offerSync(context, ref, id);
          },
        ),
        for (final pl in lists)
          ListTile(
            leading: ArtImage(pl.art, size: 44, icon: Icons.queue_music),
            title: Text(pl.name),
            subtitle: Text('${pl.count} 首歌曲'),
            onTap: () async {
              Navigator.pop(ctx);
              final added = await db.addToPlaylist(pl.id, tracks, allowDuplicates: allow);
              if (!context.mounted) return;
              final already = tracks.length - added;
              _toast(
                  context,
                  added == 0
                      ? (tracks.length == 1 ? '已在「${pl.name}」中' : '這些歌曲都已在「${pl.name}」中')
                      : already > 0
                          ? '已加入 $added 首到「${pl.name}」，$already 首已在清單中'
                          : '已加入「${pl.name}」');
            },
          ),
      ]),
    ),
  );
}

/// Every delete/remove asks first. Returns true only if the user confirmed.
Future<bool> confirmDelete(BuildContext context, {required String title, String? message, String action = '移除'}) async {
  final ok = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Marks the part of the UI that has the player bar (mini player / desktop
/// bar) at the bottom, so toasts there can avoid covering it.
class PlayerBarScope extends InheritedWidget {
  const PlayerBarScope({super.key, required super.child});

  static bool contains(BuildContext context) => context.getInheritedWidgetOfExactType<PlayerBarScope>() != null;

  @override
  bool updateShouldNotify(PlayerBarScope oldWidget) => false;
}

void _toast(BuildContext context, String msg) => toast(context, msg);

/// Short message, always at the top of the screen with the same look on
/// every page and dialog (a bottom snackbar only if there is no overlay).
void toast(BuildContext context, String msg) {
  if (!_TopToast.show(context, msg)) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg)));
  }
}

class _TopToast extends StatefulWidget {
  const _TopToast({required this.message, required this.onDone});
  final String message;
  final VoidCallback onDone;

  static OverlayEntry? _current;

  /// False when there is no overlay to show it on.
  static bool show(BuildContext context, String msg) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return false;
    _current?.remove();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _TopToast(
        message: msg,
        onDone: () {
          if (_current == entry) _current = null;
          if (entry.mounted) entry.remove();
        },
      ),
    );
    _current = entry;
    overlay.insert(entry);
    return true;
  }

  @override
  State<_TopToast> createState() => _TopToastState();
}

class _TopToastState extends State<_TopToast> with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 250))..forward();

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 2), () async {
      if (!mounted) return;
      await _anim.reverse();
      widget.onDone();
    });
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Same look as the default SnackBar, just anchored under the status bar.
    final theme = Theme.of(context);
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, -1.5), end: Offset.zero).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic)),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Material(
                  elevation: 6,
                  borderRadius: BorderRadius.circular(8),
                  color: theme.snackBarTheme.backgroundColor ?? theme.colorScheme.inverseSurface,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    child: Text(widget.message, style: TextStyle(color: theme.colorScheme.onInverseSurface, fontSize: 14)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
