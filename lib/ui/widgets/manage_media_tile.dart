import 'package:flutter/material.dart';

import '../../services/file_trash.dart';
import 'dialogs.dart';

/// 允許管理媒體檔案: shows whether 媒體管理 is allowed and opens the system
/// page to allow it; re-checks when the user comes back to the app.
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
    final v = await canManageMedia();
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
        title: const Text('允許管理媒體檔案'),
        subtitle: Text(_allowed == null
            ? '檢查中…'
            : _allowed!
                ? '已允許：刪除、移到垃圾桶、編輯資訊時，系統不會再跳出確認（OuOPlayer 自己的警告仍會出現）'
                : '未允許：刪除不是 OuOPlayer 下載的檔案時，系統每次都會再問一次。點這裡到系統設定允許'),
        trailing: Icon(_allowed == true ? Icons.check_circle : Icons.open_in_new),
        onTap: () async {
          if (!await openManageMediaSettings() && context.mounted) {
            toast(context, '這個功能需要 Android 12 以上');
          }
        },
      );
}
