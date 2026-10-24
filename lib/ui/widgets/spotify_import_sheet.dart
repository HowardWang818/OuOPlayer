import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/spotify_import.dart';
import 'dialogs.dart';

/// 匯入 Spotify 歌單: pick Spotify's export files (Playlist*.json,
/// YourLibrary.json) or Exportify CSVs, preview what is in the library,
/// choose what to import. Only songs already on the device are used.
Future<void> importSpotify(BuildContext context, WidgetRef ref) async {
  final picked = await FilePicker.pickFiles(dialogTitle: '選擇 Spotify 匯出的檔案（可多選）', type: FileType.any);
  if (picked.isEmpty) return;
  final playlists = <SpotifyPlaylist>[];
  for (final f in picked) {
    final path = f.path;
    if (path == null || !{'.json', '.csv'}.contains(p.extension(path).toLowerCase())) continue;
    try {
      final text = utf8.decode(await File(path).readAsBytes(), allowMalformed: true);
      playlists.addAll(parseSpotifyExport(text, fileName: f.name));
    } catch (_) {}
  }
  if (!context.mounted) return;
  if (playlists.isEmpty) {
    toast(context, '這些檔案裡找不到 Spotify 歌單（支援 Playlist*.json、YourLibrary.json、Exportify 的 CSV）');
    return;
  }
  final db = ref.read(dbProvider);
  final matcher = SpotifyMatcher(await db.tracks());
  final found = [for (final pl in playlists) [for (final s in pl.songs) matcher.find(s)]];
  final existing = {for (final pl in await db.playlists()) pl.name: pl.id};
  if (!context.mounted) return;

  final chosen = <int>{for (var i = 0; i < playlists.length; i++) if (found[i].any((t) => t != null)) i};
  var likedToFavorites = true;
  var mergeExisting = false;
  final hasConflict = playlists.any((pl) => !pl.liked && existing.containsKey(pl.name));
  final go = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('匯入 Spotify 歌單'),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('只會用你手機上已經有的歌，找不到的歌會列出來，不會自動下載。'),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (var i = 0; i < playlists.length; i++)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: chosen.contains(i),
                    onChanged: (v) => setState(() => v == true ? chosen.add(i) : chosen.remove(i)),
                    title: Text(playlists[i].name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${playlists[i].songs.length} 首，手機上找到 ${found[i].whereType<Track>().length} 首'
                        '${!playlists[i].liked && existing.containsKey(playlists[i].name) ? ' • 已有同名清單' : ''}'),
                  ),
              ]),
            ),
            if (playlists.any((pl) => pl.liked)) ...[
              const Divider(),
              const Text('Spotify 按讚的歌：'),
              RadioGroup<bool>(
                groupValue: likedToFavorites,
                onChanged: (v) => setState(() => likedToFavorites = v!),
                child: const Column(children: [
                  RadioListTile<bool>(contentPadding: EdgeInsets.zero, value: true, title: Text('加到「已按讚的歌曲」')),
                  RadioListTile<bool>(contentPadding: EdgeInsets.zero, value: false, title: Text('建立成「Spotify 按讚」播放清單')),
                ]),
              ),
            ],
            if (hasConflict) ...[
              const Divider(),
              const Text('已有同名的播放清單時：'),
              RadioGroup<bool>(
                groupValue: mergeExisting,
                onChanged: (v) => setState(() => mergeExisting = v!),
                child: const Column(children: [
                  RadioListTile<bool>(contentPadding: EdgeInsets.zero, value: false, title: Text('建立新的（名稱加上「(Spotify)」）')),
                  RadioListTile<bool>(contentPadding: EdgeInsets.zero, value: true, title: Text('加進現有的清單')),
                ]),
              ),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: chosen.isEmpty ? null : () => Navigator.pop(ctx, true), child: const Text('匯入')),
        ],
      ),
    ),
  );
  if (go != true || !context.mounted) return;

  final allowDup = ref.read(settingsProvider).allowPlaylistDuplicates;
  final report = <String>[];
  final missing = <String>[];
  for (final i in chosen.toList()..sort()) {
    final pl = playlists[i];
    final tracks = found[i].whereType<Track>().toList();
    for (var j = 0; j < pl.songs.length; j++) {
      if (found[i][j] == null) missing.add('${pl.name}：${pl.songs[j].label}');
    }
    if (pl.liked && likedToFavorites) {
      final liked = await db.favoriteIds();
      var added = 0;
      for (final t in tracks) {
        if (liked.add(t.id)) {
          await db.setFavorite(t, true);
          added++;
        }
      }
      report.add('已按讚的歌曲：新增 $added 首');
      continue;
    }
    int id;
    if (existing.containsKey(pl.name) && mergeExisting && !pl.liked) {
      id = existing[pl.name]!;
    } else {
      id = await db.createPlaylist(existing.containsKey(pl.name) ? '${pl.name} (Spotify)' : pl.name);
    }
    // A fresh playlist keeps Spotify's order and repeats.
    final added = await db.addToPlaylist(id, tracks, allowDuplicates: !existing.containsKey(pl.name) || allowDup || !mergeExisting);
    report.add('${pl.name}：$added / ${pl.songs.length} 首');
  }
  if (!context.mounted) return;
  await showDialog(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => AlertDialog(
      title: const Text('匯入完成'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final r in report) Text('• $r'),
          if (missing.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('有 ${missing.length} 首在手機上找不到：'),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView(shrinkWrap: true, children: [for (final m in missing) Text(m, style: const TextStyle(fontSize: 13))]),
            ),
          ],
        ]),
      ),
      actions: [
        if (missing.isNotEmpty)
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: missing.join('\n')));
              if (ctx.mounted) toast(ctx, '已複製找不到的歌曲清單');
            },
            child: const Text('複製找不到的歌'),
          ),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('好')),
      ],
    ),
  );
}
