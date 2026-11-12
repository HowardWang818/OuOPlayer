import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../../services/file_trash.dart';
import 'dialogs.dart';

/// 所有檔案存取權 (Android): on, deleting, moving and editing songs no longer
/// brings up Android's confirmation. Re-checks when the user comes back.
class ManageMediaTile extends StatefulWidget {
  const ManageMediaTile({super.key});

  @override
  State<ManageMediaTile> createState() => _ManageMediaTileState();
}

class _ManageMediaTileState extends State<ManageMediaTile> {
  late final AppLifecycleListener _lifecycle;
  bool? _allowed;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _check);
    _check();
  }

  Future<void> _check() async {
    final v = await hasAllFilesAccess();
    if (mounted) setState(() => _allowed = v);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(_allowed == true ? Icons.verified_user_outlined : Icons.admin_panel_settings_outlined),
        title: const Text('所有檔案存取權'),
        subtitle: Text(_allowed == null ? '' : (_allowed! ? '已開啟' : '開啟後，刪除與編輯歌曲不再跳出系統確認')),
        trailing: Icon(_allowed == true ? Icons.check_circle : Icons.open_in_new),
        onTap: () async {
          if (!await openAllFilesSettings() && context.mounted) toast(context, '需要 Android 11 以上');
        },
      );
}

/// Before deleting or editing files on Android: once, offers to turn on
/// 所有檔案存取權 when it is off.
Future<void> offerAllFilesAccess(BuildContext context, WidgetRef ref) async {
  const key = 'all_files_offered';
  final db = ref.read(dbProvider);
  if (await hasAllFilesAccess() || (await db.allSettings())[key] == 'true' || !context.mounted) return;
  await db.setSetting(key, 'true');
  if (!context.mounted) return;
  final go = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => AlertDialog(
      title: const Text('開啟所有檔案存取權？'),
      content: const Text('開啟後，刪除與編輯歌曲不再跳出系統確認。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('以後再說')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('前往設定')),
      ],
    ),
  );
  if (go == true) await openAllFilesSettings();
}
