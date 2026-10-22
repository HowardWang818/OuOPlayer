import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
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
            await db.addToPlaylist(id, tracks);
            if (context.mounted) _toast(context, '已加入「$name」');
          },
        ),
        for (final pl in lists)
          ListTile(
            leading: ArtImage(pl.art, size: 44, icon: Icons.queue_music),
            title: Text(pl.name),
            subtitle: Text('${pl.count} 首歌曲'),
            onTap: () async {
              Navigator.pop(ctx);
              await db.addToPlaylist(pl.id, tracks);
              if (context.mounted) _toast(context, '已加入「${pl.name}」');
            },
          ),
      ]),
    ),
  );
}

void _toast(BuildContext context, String msg) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg)));

void toast(BuildContext context, String msg) => _toast(context, msg);
