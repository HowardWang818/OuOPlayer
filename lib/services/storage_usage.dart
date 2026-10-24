import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Folders OuOPlayer fills by itself (never the user's music).
enum CacheKind {
  art('封面快取', '歌曲封面的縮圖。只清除音樂庫已經用不到的。'),
  lyrics('歌詞快取', '從 LRCLIB 查到的歌詞和「查不到」的紀錄。清除後會重新上網查詢，手動選過的歌詞也要重選。'),
  downloads('下載暫存檔', '下載中或下載失敗留下的暫存檔。下載進行中時不能清除。');

  const CacheKind(this.label, this.description);
  final String label;
  final String description;
}

Future<Directory> cacheDir(CacheKind kind) async => switch (kind) {
      CacheKind.art => Directory(p.join((await getApplicationSupportDirectory()).path, 'art')),
      CacheKind.lyrics => Directory(p.join((await getApplicationSupportDirectory()).path, 'lyrics')),
      CacheKind.downloads => Directory(p.join((await getTemporaryDirectory()).path, 'downloads')),
    };

/// Total size of the files under [dir] in bytes (0 if it doesn't exist).
Future<int> folderSize(Directory dir) async {
  if (!await dir.exists()) return 0;
  var total = 0;
  try {
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          total += await e.length();
        } catch (_) {}
      }
    }
  } catch (_) {}
  return total;
}

/// Deletes everything inside [dir] (the folder itself stays). Returns the
/// bytes freed.
Future<int> clearFolder(Directory dir) async {
  final before = await folderSize(dir);
  if (!await dir.exists()) return 0;
  await for (final e in dir.list(followLinks: false)) {
    try {
      await e.delete(recursive: true);
    } catch (_) {}
  }
  return before - await folderSize(dir);
}

/// 「1.2 MB」 style sizes.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}
