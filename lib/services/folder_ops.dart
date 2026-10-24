import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../data/db/database.dart';
import '../data/models/track.dart';

/// Why [name] can't be a folder name, or null if it can.
String? folderNameError(String name) {
  final n = name.trim();
  if (n.isEmpty) return '請輸入名稱';
  if (n == '.' || n == '..') return '不能用這個名稱';
  if (RegExp(r'[\\/:*?"<>|]').hasMatch(n)) return r'名稱不能有 \ / : * ? " < > |';
  return null;
}

/// What a move or rename did.
class MoveReport {
  MoveReport(this.moved, this.failed);

  /// Old path → the song at its new path.
  final Map<String, Track> moved;
  final int failed;
}

/// 資料夾瀏覽 → 新增 / 重新命名 / 刪除資料夾, 移到資料夾. Files are moved on
/// disk and each song keeps its playlists, like and play counts.
class FolderOps {
  FolderOps(this.db, {this.mover = moveFiles});
  final AppDatabase db;

  /// Moves files (old → new); returns false if declined. Swappable in tests.
  final Future<bool> Function(Map<String, String> moves) mover;

  /// Creates [name] inside [parent]; returns its path.
  Future<String> create(String parent, String name) async {
    final err = folderNameError(name);
    if (err != null) throw err;
    final dir = Directory(p.join(parent, name.trim()));
    if (await dir.exists()) throw '已經有「${name.trim()}」這個資料夾';
    await dir.create(recursive: true);
    return dir.path;
  }

  /// A free path for [path]: 「a (2).mp3」 if taken on disk or in [taken].
  static String freePath(String path, Set<String> taken) {
    var out = path;
    for (var i = 2; File(out).existsSync() || taken.contains(out.toLowerCase()); i++) {
      out = p.join(p.dirname(path), '${p.basenameWithoutExtension(path)} ($i)${p.extension(path)}');
    }
    return out;
  }

  /// Moves [tracks] into [dest] (same file names; 「(2)」 when taken).
  Future<MoveReport> moveTracks(List<Track> tracks, String dest) async {
    final taken = <String>{};
    final moves = <String, String>{};
    for (final t in tracks) {
      if (p.equals(p.dirname(t.uri), dest)) continue;
      final to = freePath(p.join(dest, p.basename(t.uri)), taken);
      taken.add(to.toLowerCase());
      moves[t.uri] = to;
    }
    return _apply({for (final t in tracks) t.uri: t}, moves);
  }

  /// Renames [folder] to [name]; [inside] are the library's songs in it (and below).
  Future<MoveReport> renameFolder(String folder, String name, List<Track> inside) async {
    final err = folderNameError(name);
    if (err != null) throw err;
    final to = p.join(p.dirname(folder), name.trim());
    if (p.equals(to, folder)) return MoveReport(const {}, 0);
    final sameButCase = to.toLowerCase() == folder.toLowerCase();
    if (!sameButCase && await Directory(to).exists()) throw '已經有「${name.trim()}」這個資料夾';
    String newPath(String old) => p.join(to, p.relative(old, from: folder));
    // The whole folder at once when allowed (always on Windows).
    try {
      await Directory(folder).rename(to);
      final moved = {for (final t in inside) t.uri: newPath(t.uri)};
      await db.moveTrackPaths(moved);
      return MoveReport({for (final t in inside) t.uri: t.movedTo(newPath(t.uri))}, 0);
    } on FileSystemException {
      if (!Platform.isAndroid) rethrow;
    }
    // Android: songs other apps saved go one by one through the system.
    final report = await _apply({for (final t in inside) t.uri: t}, {for (final t in inside) t.uri: newPath(t.uri)});
    await _moveOthers(folder, newPath);
    await removeEmptyDirs(folder);
    return report;
  }

  Future<MoveReport> _apply(Map<String, Track> byPath, Map<String, String> moves) async {
    if (moves.isEmpty) return MoveReport(const {}, 0);
    for (final to in moves.values.map(p.dirname).toSet()) {
      try {
        await Directory(to).create(recursive: true);
      } catch (_) {}
    }
    if (!await mover(moves)) return MoveReport(const {}, moves.length);
    final done = {for (final e in moves.entries) if (File(e.value).existsSync() && !File(e.key).existsSync()) e.key: e.value};
    // A same-name .lrc goes along when it can.
    for (final e in done.entries) {
      final lrc = File('${p.withoutExtension(e.key)}.lrc');
      if (lrc.existsSync()) {
        try {
          await lrc.rename('${p.withoutExtension(e.value)}.lrc');
        } catch (_) {}
      }
    }
    await db.moveTrackPaths(done);
    return MoveReport({for (final e in done.entries) e.key: byPath[e.key]!.movedTo(e.value)}, moves.length - done.length);
  }

  /// Other files left in a renamed folder (covers, .lrc): moved when allowed.
  Future<void> _moveOthers(String folder, String Function(String) newPath) async {
    final dir = Directory(folder);
    if (!await dir.exists()) return;
    await for (final f in dir.list(recursive: true, followLinks: false)) {
      if (f is! File) continue;
      try {
        await Directory(p.dirname(newPath(f.path))).create(recursive: true);
        await f.rename(newPath(f.path));
      } catch (_) {}
    }
  }

  /// Deletes [folder] and the empty folders in it, deepest first. Returns
  /// false if something is left (files OuOPlayer may not delete).
  static Future<bool> removeEmptyDirs(String folder) async {
    final dir = Directory(folder);
    if (!await dir.exists()) return true;
    final dirs = [
      for (final e in dir.listSync(recursive: true, followLinks: false))
        if (e is Directory) e,
    ]..sort((a, b) => b.path.length.compareTo(a.path.length));
    for (final d in [...dirs, dir]) {
      try {
        if (d.listSync().isEmpty) await d.delete();
      } catch (_) {}
    }
    return !await dir.exists();
  }
}

/// Moves files: renamed directly where allowed; on Android the others go
/// through MediaStore (one system confirmation unless 媒體管理 is on).
Future<bool> moveFiles(Map<String, String> moves) async {
  if (Platform.isAndroid) {
    try {
      return await const MethodChannel('ouo/trash').invokeMethod<bool>('move', {
            'moves': [for (final e in moves.entries) {'from': e.key, 'to': e.value}],
          }) ??
          false;
    } on PlatformException catch (e) {
      throw e.message ?? '移動失敗';
    }
  }
  for (final e in moves.entries) {
    try {
      await File(e.key).rename(e.value);
    } on FileSystemException {
      // Another drive: copy, then delete the original.
      await File(e.key).copy(e.value);
      await File(e.key).delete();
    }
  }
  return true;
}
