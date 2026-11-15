import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart' show rootNavigatorKey;

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import 'playlist_picker.dart';
import '../../theme/looks.dart';

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

/// 加入播放清單 for songs of the library (1.20.10): the playlists they are
/// in come ticked (— when only some are), tick or untick, then 完成.
/// Unticking takes the songs out of that playlist.
Future<void> showAddToPlaylist(BuildContext context, WidgetRef ref, List<Track> tracks) async {
  if (tracks.isEmpty) return;
  final db = ref.read(dbProvider);
  final allow = ref.read(settingsProvider).allowPlaylistDuplicates;
  final ids = {for (final t in tracks) t.id};
  final members = await db.playlistMembers(ids);
  final lists = await db.playlists();
  final start = {for (final p in lists) p.id: tickFor(members[p.id]?.length ?? 0, ids.length)};
  if (!context.mounted) return;
  final after = await pickPlaylists(context, start);
  if (after == null) return;
  final change = playlistChanges(start, after);
  for (final id in change.add) {
    final have = members[id] ?? const <String>{};
    await db.addToPlaylist(id, [for (final t in tracks) if (!have.contains(t.id)) t], allowDuplicates: allow);
  }
  for (final id in change.remove) {
    await db.removeTracksFromPlaylist(id, ids);
  }
  if (!context.mounted || (change.add.isEmpty && change.remove.isEmpty)) return;
  final names = {for (final p in await db.playlists()) p.id: p.name};
  String which(Set<int> s) => s.length <= 2 ? s.map((id) => '「${names[id] ?? ''}」').join('、') : ' ${s.length} 個播放清單';
  if (!context.mounted) return;
  _toast(context, [
    if (change.add.isNotEmpty) '已加入${which(change.add)}',
    if (change.remove.isNotEmpty) '已從${which(change.remove)}移除',
  ].join('，'));
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
/// every page and dialog, never at the bottom (CLAUDE.md). A context above
/// the app's overlay (sync's [rootNavigatorKey] one) uses the root
/// navigator's overlay.
/// [action]: a button on the right (「更改」), shown a little longer; the
/// message goes away when it is pressed.
void toast(BuildContext context, String msg, {String? action, VoidCallback? onAction}) {
  if (!_TopToast.show(context, msg, action: action, onAction: onAction)) debugPrint('toast with nowhere to show: $msg');
}

class _TopToast extends StatefulWidget {
  const _TopToast({required this.message, required this.onDone, this.action, this.onAction});
  final String message;
  final VoidCallback onDone;
  final String? action;
  final VoidCallback? onAction;

  static OverlayEntry? _current;

  /// False when there is no overlay to show it on.
  static bool show(BuildContext context, String msg, {String? action, VoidCallback? onAction}) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true) ?? rootNavigatorKey.currentState?.overlay;
    if (overlay == null) return false;
    _current?.remove();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _TopToast(
        message: msg,
        action: action,
        onAction: onAction,
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
    Future.delayed(Duration(seconds: widget.action == null ? 2 : 5), _close);
  }

  bool _closing = false;

  Future<void> _close() async {
    if (!mounted || _closing) return;
    _closing = true;
    await _anim.reverse();
    widget.onDone();
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
                  borderRadius: BorderRadius.circular(Looks.of(context).radius(8)),
                  color: theme.snackBarTheme.backgroundColor ?? theme.colorScheme.inverseSurface,
                  child: widget.action == null
                      ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          child: Text(widget.message, style: TextStyle(color: theme.colorScheme.onInverseSurface, fontSize: 14)),
                        )
                      : Padding(
                          padding: const EdgeInsets.only(left: 16, right: 6),
                          child: Row(children: [
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                child: Text(widget.message, style: TextStyle(color: theme.colorScheme.onInverseSurface, fontSize: 14)),
                              ),
                            ),
                            TextButton(
                              style: TextButton.styleFrom(foregroundColor: theme.colorScheme.inversePrimary),
                              onPressed: () {
                                _close();
                                widget.onAction?.call();
                              },
                              child: Text(widget.action!),
                            ),
                          ]),
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
