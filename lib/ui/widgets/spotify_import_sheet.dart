import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/missing_songs.dart';
import '../../services/song_matcher.dart';
import '../../services/spotify_import.dart';
import '../pages/missing_songs_page.dart';
import 'dialogs.dart';
import '../../config/device_words.dart';

/// 匯入 Spotify 歌單: pick Spotify's export files (Playlist*.json,
/// YourLibrary.json) or Exportify CSVs, preview what is in the library,
/// choose what to import. Songs on the device are used (「maybe」 matches
/// only once the user confirms them); the others stay in the playlist as
/// greyed placeholders that fill in when the song turns up. Nothing is
/// downloaded.
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
  final matched = [for (final pl in playlists) [for (final s in pl.songs) matcher.match(s)]];
  final found = [for (final row in matched) [for (final (t, level) in row) level == MatchLevel.sure ? t : null]];
  final existing = {for (final pl in await db.playlists()) pl.name: pl.id};
  if (!context.mounted) return;

  final chosen = <int>{for (var i = 0; i < playlists.length; i++) i};
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
            Text('會用你$thisDevice上已經有的歌；還沒有的歌會以灰色留在清單裡，之後下載或加入音樂庫時自動補上。不會自動下載。'),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (var i = 0; i < playlists.length; i++)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: chosen.contains(i),
                    onChanged: (v) => setState(() => v == true ? chosen.add(i) : chosen.remove(i)),
                    title: Text(playlists[i].name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${playlists[i].songs.length} 首，$thisDevice上找到 ${found[i].whereType<Track>().length} 首'
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

  // 「Maybe」 matches: used only for the ones the user ticks.
  final maybes = <(int, int)>[
    for (final i in chosen)
      for (var j = 0; j < matched[i].length; j++)
        if (matched[i][j].$2 == MatchLevel.maybe) (i, j),
  ];
  if (maybes.isNotEmpty) {
    final accept = <(int, int)>{};
    final ok = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('有 ${maybes.length} 首可能是同一首歌'),
          content: SizedBox(
            width: 460,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('勾選確定是同一首的；沒勾的會先以灰色留在清單裡。'),
              Flexible(
                child: ListView(shrinkWrap: true, children: [
                  for (final m in maybes)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: accept.contains(m),
                      onChanged: (v) => setState(() => v == true ? accept.add(m) : accept.remove(m)),
                      title: Text('Spotify：${playlists[m.$1].songs[m.$2].label}', maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text('$thisDevice上：${matched[m.$1][m.$2].$1!.title} - ${matched[m.$1][m.$2].$1!.artist}',
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                    ),
                ]),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消匯入')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('繼續')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    for (final (i, j) in accept) {
      found[i][j] = matched[i][j].$1;
    }
  }

  final allowDup = ref.read(settingsProvider).allowPlaylistDuplicates;
  final report = <String>[];
  final missing = <String>[];
  var total = 0;
  for (final i in chosen.toList()..sort()) {
    final pl = playlists[i];
    // Spotify's order, with placeholders where the song isn't here yet.
    final tracks = <Track>[];
    for (var j = 0; j < pl.songs.length; j++) {
      final t = found[i][j];
      if (t != null) {
        tracks.add(t);
      } else {
        final song = pl.songs[j];
        missing.add('${pl.name}：${song.label}');
        tracks.add(await MissingSongs.create(db, song.title, song.artists.join(', '), album: song.album ?? '', durationMs: song.durationMs));
      }
    }
    final onDevice = found[i].whereType<Track>().length;
    total += pl.songs.length;
    if (pl.liked && likedToFavorites) {
      final liked = await db.favoriteIds();
      var added = 0;
      for (final t in tracks) {
        if (liked.add(t.id)) {
          await db.setFavorite(t, true);
          added++;
        }
      }
      report.add('已按讚的歌曲：新增 $added 首（其中 ${pl.songs.length - onDevice} 首$thisDevice上還沒有）');
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
    report.add('${pl.name}：$thisDevice上有 $onDevice / ${pl.songs.length} 首${added < tracks.length ? '（$added 首加入）' : ''}');
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
            Text('有 ${missing.length} 首$thisDevice上還沒有，已用灰色留在清單裡，之後有了會自動補上：'),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView(shrinkWrap: true, children: [for (final m in missing) Text(m, style: const TextStyle(fontSize: 13))]),
            ),
            if (suggestSoundiiz(missing.length, total)) const SoundiizTip(),
          ],
        ]),
      ),
      actions: [
        if (missing.isNotEmpty)
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: missing.join('\n')));
              if (ctx.mounted) toast(ctx, '已複製缺少的歌曲清單');
            },
            child: const Text('複製'),
          ),
        if (missing.isNotEmpty)
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => const MissingSongsPage()));
            },
            child: const Text('取得 YouTube Music 連結'),
          ),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('好')),
      ],
    ),
  );
}
