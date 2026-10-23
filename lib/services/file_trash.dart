import 'dart:io';

import 'package:flutter/services.dart';

/// Moves a file to the Recycle Bin (Windows) or the system trash (Android 11+)
/// instead of deleting it for good. Returns false if the user declined or it
/// failed; throws with a readable message on errors worth showing.
Future<bool> moveToTrash(String path) async {
  if (Platform.isWindows) {
    // The path goes in through an environment variable, never into the script text.
    final r = await Process.run(
      'powershell',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r"Add-Type -AssemblyName Microsoft.VisualBasic; [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($env:OUO_TRASH_PATH, 'OnlyErrorDialogs', 'SendToRecycleBin')",
      ],
      environment: {'OUO_TRASH_PATH': path},
    );
    if (r.exitCode != 0) throw '無法移到資源回收筒：${(r.stderr as String).trim()}';
    return !File(path).existsSync();
  }
  if (Platform.isAndroid) {
    try {
      return await const MethodChannel('ouo/trash').invokeMethod<bool>('trash', {'path': path}) ?? false;
    } on PlatformException catch (e) {
      throw e.message ?? '刪除失敗';
    }
  }
  await File(path).delete();
  return true;
}

String get trashName => Platform.isWindows ? '資源回收筒' : '垃圾桶';
