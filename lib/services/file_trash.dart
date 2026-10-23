import 'dart:io';

import 'package:flutter/services.dart';

/// Moves files to the Recycle Bin (Windows) or the system trash (Android 11+)
/// instead of deleting them for good. On Android one confirmation dialog
/// covers all files. Returns false if the user declined; throws with a
/// readable message on errors worth showing.
Future<bool> moveToTrash(List<String> paths) async {
  if (paths.isEmpty) return true;
  if (Platform.isWindows) {
    // Paths go in through an environment variable, never into the script text.
    final r = await Process.run(
      'powershell',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'''Add-Type -AssemblyName Microsoft.VisualBasic; foreach ($f in ($env:OUO_TRASH_PATHS -split "`n")) { if ($f) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($f, 'OnlyErrorDialogs', 'SendToRecycleBin') } }''',
      ],
      environment: {'OUO_TRASH_PATHS': paths.join('\n')},
    );
    if (r.exitCode != 0) throw '無法移到資源回收筒：${(r.stderr as String).trim()}';
    return paths.every((f) => !File(f).existsSync());
  }
  if (Platform.isAndroid) {
    try {
      return await const MethodChannel('ouo/trash').invokeMethod<bool>('trash', {'paths': paths}) ?? false;
    } on PlatformException catch (e) {
      throw e.message ?? '刪除失敗';
    }
  }
  for (final f in paths) {
    await File(f).delete();
  }
  return true;
}

String get trashName => Platform.isWindows ? '資源回收筒' : '垃圾桶';
