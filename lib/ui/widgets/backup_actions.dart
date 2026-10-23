import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../../services/backup.dart';
import 'dialogs.dart';

/// 備份: saves everything the user made as one .json file they place.
Future<void> exportBackup(BuildContext context, WidgetRef ref) async {
  try {
    final data = await buildBackup(ref.read(dbProvider));
    final d = DateTime.now();
    final name = 'OuOPlayer備份_${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}.json';
    final saved = await FilePicker.saveFile(
      dialogTitle: '儲存備份',
      fileName: name,
      bytes: utf8.encode(const JsonEncoder.withIndent(' ').convert(data)),
      mimeType: 'application/json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (saved != null && context.mounted) toast(context, '已備份：$name');
  } catch (e) {
    if (context.mounted) toast(context, '備份失敗：$e');
  }
}

/// 還原: replaces the current playlists, likes, play counts, podcasts and
/// settings with a backup, after a warning.
Future<void> importBackup(BuildContext context, WidgetRef ref) async {
  final picked = await FilePicker.pickFiles(dialogTitle: '選擇 OuOPlayer 備份檔', type: FileType.any);
  final path = picked.firstOrNull?.path;
  if (path == null) return;
  final Map<String, Object?> data;
  try {
    data = (jsonDecode(await File(path).readAsString()) as Map).cast<String, Object?>();
    if (data['app'] != 'OuOPlayer') throw '這不是 OuOPlayer 的備份檔';
  } catch (e) {
    if (context.mounted) toast(context, '無法讀取備份：$e');
    return;
  }
  if (!context.mounted) return;
  final lists = (data['playlists'] as List? ?? const []).length;
  final likes = (data['favorites'] as List? ?? const []).length;
  final when = (data['exported_at'] as String? ?? '').replaceFirst('T', ' ').split('.').first;
  if (!await confirmDelete(context,
      title: '用備份取代目前的資料？',
      message: '備份時間：$when\n內容：$lists 個播放清單、$likes 首按讚的歌曲、播放次數、Podcast 訂閱和設定。\n\n'
          '目前的播放清單、資料夾、已按讚的歌曲、播放次數、Podcast 訂閱和設定會被取代，無法復原（可以先備份目前的資料）。音樂檔案不會被動到。',
      action: '還原')) {
    return;
  }
  try {
    final report = await restoreBackup(ref.read(dbProvider), ref.read(scannerProvider), data);
    await ref.read(settingsProvider.notifier).reload();
    if (!context.mounted) return;
    await showDialog(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        title: const Text('還原完成'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('還原了 ${report.playlists} 個播放清單（共 ${report.songs} 首）。部分設定在重新開啟 App 後生效。'),
            if (report.missing.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('有 ${report.missing.length} 首在這台裝置的音樂庫裡找不到，已略過：'),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView(shrinkWrap: true, children: [for (final m in report.missing) Text('• $m')]),
              ),
            ],
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('好'))],
      ),
    );
  } catch (e) {
    if (context.mounted) toast(context, '還原失敗：$e');
  }
}
