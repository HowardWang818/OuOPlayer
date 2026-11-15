import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../../providers/sync_provider.dart' show offerSyncIn;
import 'art_image.dart';
import 'dialogs.dart';

/// A playlist's tick for [songs] songs, [inList] of them already in it:
/// all → ticked, none → empty, some → partly (null, shown as —).
bool? tickFor(int inList, int songs) => inList <= 0 ? false : (inList >= songs ? true : null);

/// What the ticks became: the playlists to add the songs to (newly ticked)
/// and to take them out of (newly emptied). A playlist left partly ticked
/// stays as it was.
({Set<int> add, Set<int> remove}) playlistChanges(Map<int, bool?> before, Map<int, bool?> after) {
  final add = <int>{}, remove = <int>{};
  for (final e in after.entries) {
    final was = before[e.key] ?? false;
    if (e.value == true && was != true) add.add(e.key);
    if (e.value == false && was != false) remove.add(e.key);
  }
  return (add: add, remove: remove);
}

/// The next tick when tapped: ticked ↔ empty; a playlist that began partly
/// ticked goes — → ticked → empty → — again.
bool? nextTick(bool? now, bool? began) {
  if (began == null) return now == null ? true : (now == true ? false : null);
  return now != true;
}

/// 加入播放清單 (1.20.10, the same sheet everywhere): tick the playlists,
/// then 完成. [start]: each playlist's tick to begin with (see [tickFor]).
/// Returns every playlist's tick (new playlists made here ticked); null:
/// closed without 完成.
Future<Map<int, bool?>?> pickPlaylists(BuildContext context, Map<int, bool?> start) async {
  final db = ProviderScope.containerOf(context, listen: false).read(dbProvider);
  var lists = await db.playlists();
  if (!context.mounted) return null;
  final ticks = <int, bool?>{for (final p in lists) p.id: start[p.id] ?? false};
  final began = <int, bool?>{...ticks};
  return showModalBottomSheet<Map<int, bool?>>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
              child: Row(children: [
                const Expanded(child: Text('加入播放清單', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
                FilledButton(onPressed: () => Navigator.pop(ctx, {...ticks}), child: const Text('完成')),
              ]),
            ),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                ListTile(
                  leading: const Icon(Icons.add),
                  title: const Text('新增播放清單'),
                  onTap: () async {
                    final fallback = '我的播放清單 #${lists.length + 1}';
                    final name = await promptText(ctx, title: '為播放清單命名', hint: fallback);
                    if (name == null) return;
                    final id = await db.createPlaylist(name.isEmpty ? fallback : name);
                    if (ctx.mounted) await offerSyncIn(ctx, id);
                    lists = await db.playlists();
                    began[id] = false;
                    setState(() => ticks[id] = true);
                  },
                ),
                for (final pl in lists)
                  CheckboxListTile(
                    value: ticks[pl.id],
                    tristate: began[pl.id] == null,
                    onChanged: (_) => setState(() => ticks[pl.id] = nextTick(ticks[pl.id], began[pl.id])),
                    secondary: ArtImage(pl.art, size: 44, icon: Icons.queue_music),
                    title: Text(pl.name),
                    subtitle: Text('${pl.count} 首歌曲'),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    ),
  );
}
