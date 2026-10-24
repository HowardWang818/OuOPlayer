import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/missing_songs.dart';
import '../../services/playlist_import.dart';
import '../pages/collection_page.dart';
import 'dialogs.dart';

/// 匯入播放清單: pick an .m3u / .m3u8 file and make a playlist of the songs
/// found in the library (online links are added as streams).
Future<void> importM3uPlaylist(BuildContext context, WidgetRef ref) async {
  final picked = await FilePicker.pickFiles(dialogTitle: '選擇 M3U 播放清單', type: FileType.any);
  final path = picked.firstOrNull?.path;
  if (path == null) return;
  if (!{'.m3u', '.m3u8'}.contains(p.extension(path).toLowerCase())) {
    if (context.mounted) toast(context, '請選擇 .m3u 或 .m3u8 檔案');
    return;
  }
  final String text;
  try {
    final bytes = await File(path).readAsBytes();
    text = utf8.decode(bytes, allowMalformed: true);
  } catch (e) {
    if (context.mounted) toast(context, '讀取失敗：$e');
    return;
  }
  final m3u = M3uPlaylist.parse(text, baseDir: p.dirname(path));
  if (m3u.entries.isEmpty) {
    if (context.mounted) toast(context, '這個檔案裡沒有歌曲');
    return;
  }
  final db = ref.read(dbProvider);
  final matcher = LibraryMatcher(await db.tracks());
  final found = <Track>[];
  final missing = <String>[];
  for (final e in m3u.entries) {
    if (e.isUrl) {
      found.add(Track.fromUrl(e.location, title: e.title, artist: e.artist, durationMs: e.durationSec == null ? null : e.durationSec! * 1000));
      continue;
    }
    final t = matcher.find(e.location, title: e.title, artist: e.artist, durationMs: e.durationSec == null ? null : e.durationSec! * 1000);
    if (t != null) {
      found.add(t);
    } else {
      missing.add(e.label);
      // Only songs the file names can be filled in later.
      if (e.title != null) {
        found.add(await MissingSongs.create(db, e.title!, e.artist ?? '', durationMs: e.durationSec == null ? null : e.durationSec! * 1000));
      }
    }
  }
  final name = (m3u.name?.isNotEmpty ?? false) ? m3u.name! : p.basenameWithoutExtension(path);
  if (found.isEmpty) {
    if (context.mounted) await _report(context, name, 0, missing);
    return;
  }
  final id = await db.createPlaylist(name);
  // Keep the file's order and repeats.
  await db.addToPlaylist(id, found, allowDuplicates: true);
  if (!context.mounted) return;
  await _report(context, name, found.where((t) => t.source != TrackSource.missing).length, missing);
  if (context.mounted) Navigator.of(context).push(MaterialPageRoute(builder: (_) => CollectionPage.playlist(id, name)));
}

Future<void> _report(BuildContext context, String name, int added, List<String> missing) => showDialog(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        title: Text(added == 0 ? '沒有匯入任何歌曲' : '已匯入「$name」'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(added == 0 ? '音樂庫裡找不到清單中的歌曲，請先把歌曲加入音樂庫再匯入。' : '加入了 $added 首。'),
            if (missing.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('有 ${missing.length} 首在音樂庫裡找不到（有歌名的已用灰色留在清單裡，之後有了會自動補上）：'),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView(shrinkWrap: true, children: [for (final m in missing) Text('• $m')]),
              ),
            ],
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('好'))],
      ),
    );
