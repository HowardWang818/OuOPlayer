import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/missing_files.dart';
import 'dialogs.dart';

/// Songs the user chose to keep this session; they aren't asked about again
/// until something else goes missing.
final Set<String> _keptThisSession = {};
bool _asking = false;

/// Looks for library songs whose file is gone and, after asking, removes
/// them from the library, playlists and likes (albums and artists that only
/// had those songs disappear with them) and drops unused cover images.
/// With [manual], also says when nothing is missing.
Future<void> checkMissingFiles(BuildContext context, WidgetRef ref, {bool manual = false}) async {
  if (_asking) return;
  final s = ref.read(settingsProvider);
  final db = ref.read(dbProvider);
  final all = await db.tracks();
  final trashed = findTrashedTracks(all);
  final trashedIds = {for (final t in trashed) t.id};
  final missing = [
    ...trashed,
    ...findMissingTracks(all, {...s.musicDirs, s.downloadDir}.toList()).where((t) => !trashedIds.contains(t.id)),
  ];
  final fresh = manual ? missing : missing.where((t) => !_keptThisSession.contains(t.id)).toList();
  if (fresh.isEmpty) {
    if (manual && context.mounted) toast(context, '沒有已不存在的歌曲');
    return;
  }
  if (!context.mounted) return;
  _asking = true;
  final bool ok;
  try {
    ok = await _confirm(context, missing, trashed: trashed.length);
  } finally {
    _asking = false;
  }
  if (!ok) {
    _keptThisSession.addAll(missing.map((t) => t.id));
    return;
  }
  final handler = ref.read(audioHandlerProvider);
  for (final t in missing) {
    await handler.removeTrack(t.id);
  }
  await db.deleteTracks(missing.map((t) => t.id));
  await ref.read(scannerProvider).cleanArtCache();
  if (context.mounted) toast(context, '已從音樂庫移除 ${missing.length} 首');
}

Future<bool> _confirm(BuildContext context, List<Track> missing, {required int trashed}) async {
  final gone = missing.length - trashed;
  final title = trashed == 0
      ? '有 $gone 首歌的檔案已不存在'
      : gone == 0
          ? '有 $trashed 首是垃圾桶裡的檔案'
          : '有 ${missing.length} 首歌要從音樂庫移除';
  final why = [
    if (gone > 0) '$gone 首的檔案已不存在',
    if (trashed > 0) '$trashed 首是垃圾桶裡已刪除的檔案（垃圾桶裡的檔案不會被動到，仍可還原）',
  ].join('；');
  final albums = missing.map((t) => t.album).toSet().length;
  final artists = missing.map((t) => t.artist).toSet().length;
  final result = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$why。\n要從音樂庫、播放清單和已按讚的歌曲中移除嗎？涉及 $albums 張專輯、$artists 位演出者；只剩這些歌的專輯和演出者也會一起消失。不會刪除任何檔案。'),
          const SizedBox(height: 8),
          Flexible(
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('查看是哪幾首'),
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: ListView(shrinkWrap: true, children: [
                    for (final t in missing)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(t.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                  ]),
                ),
              ],
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('先不要')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('移除'),
        ),
      ],
    ),
  );
  return result ?? false;
}
