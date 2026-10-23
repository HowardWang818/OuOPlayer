import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/tag_editor.dart';
import 'art_image.dart';
import 'dialogs.dart';

/// 編輯資訊: title, artist, album and cover, written into the file itself
/// when its format allows (otherwise only inside OuOPlayer).
Future<void> showEditTrack(BuildContext context, WidgetRef ref, Track track) async {
  final title = TextEditingController(text: track.title);
  final artist = TextEditingController(text: track.artist == '未知演出者' ? '' : track.artist);
  final album = TextEditingController(text: track.album == '未知專輯' ? '' : track.album);
  final writable = canWriteTags(track.uri);
  Uint8List? cover;
  var coverMime = 'image/jpeg';
  final saved = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('編輯資訊'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: cover != null ? Image.memory(cover!, width: 88, height: 88, fit: BoxFit.cover) : ArtImage(track.art, size: 88),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.image_outlined),
                    label: const Text('更換封面'),
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
                ),
              ]),
              TextField(controller: title, decoration: const InputDecoration(labelText: '歌名')),
              TextField(controller: artist, decoration: const InputDecoration(labelText: '歌手')),
              TextField(controller: album, decoration: const InputDecoration(labelText: '專輯')),
              const SizedBox(height: 12),
              Text(
                writable
                    ? '會寫進音樂檔案（${p.basename(track.uri)}），其他播放器也看得到。不是 OuOPlayer 下載的檔案，系統會請你確認一次。'
                    : '${p.extension(track.uri).toUpperCase().replaceFirst('.', '')} 格式無法寫入檔案，只會在 OuOPlayer 裡修改。',
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
  if (saved != true) return;
  final edit = TagEdit(
    title: title.text.trim().isEmpty ? track.title : title.text.trim(),
    artist: artist.text.trim().isEmpty ? '未知演出者' : artist.text.trim(),
    album: album.text.trim().isEmpty ? '未知專輯' : album.text.trim(),
    cover: cover,
    coverMime: coverMime,
  );
  final handler = ref.read(audioHandlerProvider);
  try {
    if (writable) {
      // Don't rewrite the file under the player's feet.
      if (handler.currentTrack?.id == track.id && handler.player.playing) await handler.pause();
      if (await writeTags(track.uri, edit) == TagWriteResult.declined) {
        if (context.mounted) toast(context, '已取消，沒有修改');
        return;
      }
    }
    final art = edit.cover == null ? track.art : await ref.read(scannerProvider).storeArt(edit.cover!, edit.coverMime);
    final updated = Track(
      id: track.id,
      uri: track.uri,
      title: edit.title,
      artist: edit.artist,
      album: edit.album,
      durationMs: track.durationMs,
      art: art,
      source: track.source,
      trackNo: track.trackNo,
      addedAt: track.addedAt,
    );
    await ref.read(dbProvider).updateTrackInfo(updated);
    handler.updateTrackInfo(updated);
    if (context.mounted) toast(context, writable ? '已更新並寫入檔案' : '已更新（只在 OuOPlayer 裡）');
  } catch (e) {
    if (context.mounted) toast(context, '修改失敗：$e');
  }
}
