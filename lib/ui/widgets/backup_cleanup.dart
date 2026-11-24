import 'package:flutter/material.dart';

import '../../data/db/database.dart';
import '../../providers/auto_backup_provider.dart';
import '../../services/auto_backup.dart';
import '../../services/storage_usage.dart';
import 'dialogs.dart';

/// Asked once (1.23.0): backups stopped holding song covers, and the old
/// automatic ones that do are large.
const backupCleanupKey = 'backup_cleanup_asked';

/// 要清理舊備份嗎？ After an update, once: the automatic backups that hold
/// covers, with how many and how big. 清理 makes a new (small) backup first
/// and deletes them only once it was written; 保留 keeps them. Backups the
/// user saved are never touched.
/// [dir]: the backup folder (null: the default one).
Future<void> offerBackupCleanup(BuildContext context, AppDatabase db, AutoBackupNotifier backups, String? dir) async {
  if ((await db.allSettings())[backupCleanupKey] != null) return;
  dir ??= await AutoBackup.defaultDir();
  final List<BackupFile> old;
  try {
    old = await AutoBackup.withCovers(dir);
  } catch (_) {
    return;
  }
  if (old.isEmpty) {
    await db.setSetting(backupCleanupKey, 'none');
    return;
  }
  if (!context.mounted) return;
  final size = formatBytes(old.fold(0, (a, f) => a + f.bytes));
  final clean = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (c) => AlertDialog(
      title: const Text('要清理舊備份嗎？'),
      content: Text('${old.length} 份舊的自動備份，共 $size。\n新的備份不含歌曲封面。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('保留')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('清理')),
      ],
    ),
  );
  // Closed without answering: asked again next time.
  if (clean == null) return;
  await db.setSetting(backupCleanupKey, clean ? 'cleaned' : 'kept');
  if (!clean || !context.mounted) return;
  if (!await confirmDelete(context, title: '刪除這 ${old.length} 份舊備份？', message: '刪除後無法復原。', action: '刪除')) {
    await db.setSetting(backupCleanupKey, 'kept');
    return;
  }
  // A new backup first: the old ones go only once it is written.
  final error = await backups.backupNow();
  if (error != null) {
    await db.setSetting(backupCleanupKey, 'kept');
    if (context.mounted) toast(context, '備份失敗，舊備份沒有刪除：$error');
    return;
  }
  await AutoBackup.remove(old);
  if (context.mounted) toast(context, '已清理 ${old.length} 份舊備份（$size）');
}
