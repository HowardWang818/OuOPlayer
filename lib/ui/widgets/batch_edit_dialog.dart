import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/tag_editor.dart';
import 'dialogs.dart';
import '../../config/device_words.dart';

/// 批次編輯資訊: the same artist / album / cover for several songs. Empty
/// fields are left as they are; titles stay each song's own.
Future<void> showBatchEdit(BuildContext context, WidgetRef ref, List<Track> tracks) async {
  final songs = [for (final t in tracks) if (t.source == TrackSource.local || t.source == TrackSource.download) t];
  if (songs.isEmpty) {
    toast(context, '只能編輯$thisDevice上的歌曲');
    return;
  }
  final artist = TextEditingController();
  final album = TextEditingController();
  Uint8List? cover;
  var coverMime = 'image/jpeg';
  final writable = songs.where((t) => canWriteTags(t.uri)).length;
  final go = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text('編輯 ${songs.length} 首的資訊'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('只會改有填的欄位，沒填的維持各首原本的資訊。'),
              TextField(controller: artist, decoration: const InputDecoration(labelText: '歌手（不改就留空）')),
              TextField(controller: album, decoration: const InputDecoration(labelText: '專輯（不改就留空）')),
              const SizedBox(height: 12),
              Row(children: [
                if (cover != null) ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.memory(cover!, width: 56, height: 56, fit: BoxFit.cover)),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.image_outlined),
                  label: Text(cover == null ? '同一張封面（可不選）' : '換一張'),
                  onPressed: () async {
                    final picked = await FilePicker.pickFiles(type: FileType.image, dialogTitle: '選擇封面圖片');
                    final path = picked.firstOrNull?.path;
                    if (path == null) return;
                    final bytes = await File(path).readAsBytes();
                    setState(() {
                      cover = bytes;
                      coverMime = p.extension(path).toLowerCase() == '.png' ? 'image/png' : 'image/jpeg';
                    });
                  },
                ),
              ]),
              const SizedBox(height: 12),
              Text(
                '$writable 首會寫進檔案${songs.length > writable ? '，${songs.length - writable} 首（Opus 等格式）只在 OuOPlayer 裡修改' : ''}。'
                '不是 OuOPlayer 下載的檔案，若沒有允許「管理媒體檔案」，系統會逐一確認。',
                style: TextStyle(fontSize: 12, color: Theme.of(ctx).colorScheme.onSurfaceVariant),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('儲存')),
        ],
      ),
    ),
  );
  if (go != true || !context.mounted) return;
  final newArtist = artist.text.trim(), newAlbum = album.text.trim();
  if (newArtist.isEmpty && newAlbum.isEmpty && cover == null) return;
  final db = ref.read(dbProvider);
  final handler = ref.read(audioHandlerProvider);
  final art = cover == null ? null : await ref.read(scannerProvider).storeArt(cover!, coverMime);
  var ok = 0, skipped = 0;
  for (final t in songs) {
    final edit = TagEdit(
      title: t.title,
      artist: newArtist.isEmpty ? t.artist : newArtist,
      album: newAlbum.isEmpty ? t.album : newAlbum,
      cover: cover,
      coverMime: coverMime,
    );
    try {
      if (canWriteTags(t.uri)) {
        if (handler.currentTrack?.id == t.id && handler.player.playing) await handler.pause();
        if (await writeTags(t.uri, edit) == TagWriteResult.declined) {
          skipped++;
          continue;
        }
      }
      final updated = Track(
        id: t.id,
        uri: t.uri,
        title: t.title,
        artist: edit.artist,
        album: edit.album,
        durationMs: t.durationMs,
        art: art ?? t.art,
        source: t.source,
        trackNo: t.trackNo,
        addedAt: t.addedAt,
      );
      await db.updateTrackInfo(updated);
      handler.updateTrackInfo(updated);
      ok++;
    } catch (_) {
      skipped++;
    }
  }
  if (context.mounted) toast(context, skipped == 0 ? '已更新 $ok 首' : '已更新 $ok 首，$skipped 首沒有修改');
}
