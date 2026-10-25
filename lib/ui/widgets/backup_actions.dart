import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auto_backup_provider.dart';
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
  if (path == null || !context.mounted) return;
  await restoreFromFile(context, ref, path);
}

/// Restores the backup file at [path] (after a warning).
Future<void> restoreFromFile(BuildContext context, WidgetRef ref, String path) async {
  final Map<String, Object?> data;
  try {
    data = (jsonDecode(await File(path).readAsString()) as Map).cast<String, Object?>();
    if (data['app'] != 'OuOPlayer') throw '這不是 OuOPlayer 的備份檔';
  } catch (e) {
    if (context.mounted) toast(context, '無法讀取備份：$e');
    return;
  }
  if (!context.mounted) return;
  final parts = await _chooseParts(context, data);
  if (parts == null || parts.isEmpty || !context.mounted) return;
  final when = (data['exported_at'] as String? ?? '').replaceFirst('T', ' ').split('.').first;
  if (!await confirmDelete(context,
      title: '用備份取代目前的資料？',
      message: '備份時間：$when\n\n以下會被取代，無法復原（可以先備份目前的資料）：\n'
          '${[for (final p in RestorePart.values) if (parts.contains(p)) '• ${p.label}'].join('\n')}\n\n'
          '沒有勾選的部分不會改變。音樂檔案不會被動到。',
      action: '還原')) {
    return;
  }
  try {
    final report = await restoreBackup(ref.read(dbProvider), ref.read(scannerProvider), data, parts: parts);
    await ref.read(settingsProvider.notifier).reload();
    ref.invalidate(autoBackupProvider);
    if (!context.mounted) return;
    await showDialog(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        title: const Text('還原完成'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(parts.contains(RestorePart.playlists)
                ? '還原了 ${report.playlists} 個播放清單（共 ${report.songs} 首）。${parts.contains(RestorePart.settings) ? '部分設定在重新開啟 App 後生效。' : ''}'
                : '還原完成。${parts.contains(RestorePart.settings) ? '部分設定在重新開啟 App 後生效。' : ''}'),
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

/// Which parts of the backup to restore (all ticked to start with), with
/// what the backup holds for each.
Future<Set<RestorePart>?> _chooseParts(BuildContext context, Map<String, Object?> data) {
  int n(String key) => (data[key] as List? ?? const []).length;
  final what = {
    RestorePart.settings: '${(data['settings'] as Map? ?? const {}).length} 項',
    RestorePart.playlists: '${n('playlists')} 個播放清單、${n('folders')} 個資料夾',
    RestorePart.likes: '${n('favorites')} 首',
    RestorePart.history: '${n('plays')} 首的播放次數',
    RestorePart.podcasts: '${n('podcasts')} 個節目',
  };
  final picked = {...RestorePart.values};
  return showDialog<Set<RestorePart>>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('要還原哪些？'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final p in RestorePart.values)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: picked.contains(p),
                title: Text(p.label),
                subtitle: Text(what[p]!),
                onChanged: (v) => setState(() => v == true ? picked.add(p) : picked.remove(p)),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: picked.isEmpty ? null : () => Navigator.pop(ctx, {...picked}), child: const Text('下一步')),
        ],
      ),
    ),
  );
}
