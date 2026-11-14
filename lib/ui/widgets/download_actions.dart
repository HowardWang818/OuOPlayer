import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart' show rootNavigatorKey;
import '../../providers/providers.dart';
import '../../services/download_service.dart';
import '../../services/download_match.dart' show isPlaylistUrl;
import '../../services/download_target.dart';
import '../../services/network_check.dart';
import 'art_image.dart';
import 'dialogs.dart';

const downloadTermsKey = 'download_terms_ok';
const downloadTerms = '僅限下載擁有權利或無版權限制的內容。下載內容的法律責任由使用者自行承擔。';

/// 下載須知: once, before the first download.
Future<bool> acceptDownloadTerms(BuildContext context) async {
  final db = ProviderScope.containerOf(context, listen: false).read(dbProvider);
  if ((await db.allSettings())[downloadTermsKey] == 'true') return true;
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => AlertDialog(
      title: const Text('下載須知'),
      content: const Text(downloadTerms),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('同意')),
      ],
    ),
  );
  if (ok == true) await db.setSetting(downloadTermsKey, 'true');
  return ok == true;
}

/// The playlist downloads go into: the one picked within the last hour, or
/// asked now. Null: cancelled.
/// [ask]: always ask (「加入播放清單」 on a preview), without remembering.
Future<DownloadTarget?> pickDownloadTarget(BuildContext context, {bool ask = false}) async {
  final db = ProviderScope.containerOf(context, listen: false).read(dbProvider);
  final saved = DownloadTarget.decode((await db.allSettings())[DownloadTarget.key]);
  final now = DateTime.now();
  if (!ask && saved != null && saved.freshAt(now)) {
    // The playlist may have been deleted since.
    final lists = await db.playlists();
    if (saved.playlistId == null || lists.any((p) => p.id == saved.playlistId)) return saved;
  }
  final lists = await db.playlists();
  if (!context.mounted) return null;
  final picked = await showModalBottomSheet<DownloadTarget>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('下載至', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ),
        if (!ask)
          ListTile(
            leading: const Icon(Icons.library_music_outlined),
            title: const Text('僅加入音樂庫'),
            onTap: () => Navigator.pop(ctx, DownloadTarget(at: DateTime.now())),
          ),
        ListTile(
          leading: const Icon(Icons.add),
          title: const Text('新增播放清單'),
          onTap: () async {
            final name = await promptText(ctx, title: '播放清單名稱', hint: '我的播放清單 #${lists.length + 1}');
            if (name == null || !ctx.mounted) return;
            final n = name.isEmpty ? '我的播放清單 #${lists.length + 1}' : name;
            final id = await db.createPlaylist(n);
            if (ctx.mounted) Navigator.pop(ctx, DownloadTarget(playlistId: id, name: n, at: DateTime.now()));
          },
        ),
        for (final pl in lists)
          ListTile(
            leading: ArtImage(pl.art, size: 44, icon: Icons.queue_music),
            title: Text(pl.name),
            onTap: () => Navigator.pop(ctx, DownloadTarget(playlistId: pl.id, name: pl.name, at: DateTime.now())),
          ),
      ]),
    ),
  );
  if (picked != null && !ask) await db.setSetting(DownloadTarget.key, picked.encode());
  return picked;
}

/// Downloads one song (or a single-video link) into the chosen playlist.
/// Playlist links keep making their own playlist. [ask]: false for songs
/// that fill a missing place by themselves (缺少的歌曲).
Future<bool> startDownload(BuildContext context, String url,
    {String? title, String? artist, String? album, String? art, bool ask = true, bool like = false, bool askPlaylist = false}) async {
  final c = ProviderScope.containerOf(context, listen: false);
  if (!await acceptDownloadTerms(context) || !context.mounted) return false;
  if (!await okToDownload(context, warn: c.read(settingsProvider).wifiWarning) || !context.mounted) return false;
  DownloadTarget? target;
  if (ask && !isPlaylistUrl(url)) {
    target = await pickDownloadTarget(context, ask: askPlaylist);
    if (target == null) return false;
  }
  final task = c.read(downloadServiceProvider).add(url, format: c.read(settingsProvider).ytFormat, title: title, artist: artist, album: album, playlistId: target?.playlistId, playlistName: target?.name, like: like, art: art);
  if (context.mounted) {
    final msg = like ? '已加入下載，完成後加入已按讚的歌曲' : target?.name == null ? '已加入下載' : '已加入下載，完成後加入「${target!.name}」';
    if (like || isPlaylistUrl(url)) {
      toast(context, msg);
    } else {
      toast(context, msg, action: '更改', onAction: () => changeDownloadPlaylistsLater(task));
    }
  }
  return true;
}

/// 打開資料夾 of a download (1.20.9). Windows: File Explorer with the file
/// selected. Android: the system Files app at its folder; where that isn't
/// possible, the folder's path to copy.
Future<void> openDownloadFolder(BuildContext context, String path) async {
  if (!File(path).existsSync() && !Directory(path).existsSync()) {
    toast(context, '找不到這個檔案');
    return;
  }
  if (Platform.isWindows) {
    await Process.run('explorer.exe', ['/select,', path]);
    return;
  }
  final dir = Directory(path).existsSync() ? path : File(path).parent.path;
  var opened = false;
  try {
    opened = await const MethodChannel('ouo/folder').invokeMethod<bool>('open', {'path': dir}) ?? false;
  } catch (_) {}
  if (opened || !context.mounted) return;
  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => AlertDialog(
      title: const Text('檔案位置'),
      content: SelectableText(dir),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('關閉')),
        FilledButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: dir));
            Navigator.pop(ctx);
            toast(context, '已複製位置');
          },
          child: const Text('複製'),
        ),
      ],
    ),
  );
}

/// 「更改」 pressed on a message: the picker, on the app's root navigator.
void changeDownloadPlaylistsLater(DownloadTask task) {
  final ctx = rootNavigatorKey.currentContext;
  if (ctx != null && ctx.mounted) changeDownloadPlaylists(ctx, task);
}

/// Picks playlists (several at once). [selected]: ticked to begin with.
/// Returns the ticked ones in the playlists' order; null: cancelled.
Future<List<int>?> pickPlaylists(BuildContext context, Set<int> selected) async {
  final db = ProviderScope.containerOf(context, listen: false).read(dbProvider);
  var lists = await db.playlists();
  if (!context.mounted) return null;
  final ticked = {...selected};
  return showModalBottomSheet<List<int>>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
              child: Row(children: [
                const Expanded(child: Text('加入播放清單', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, [for (final p in lists) if (ticked.contains(p.id)) p.id]),
                  child: const Text('完成'),
                ),
              ]),
            ),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                ListTile(
                  leading: const Icon(Icons.add),
                  title: const Text('新增播放清單'),
                  onTap: () async {
                    final name = await promptText(ctx, title: '播放清單名稱', hint: '我的播放清單 #${lists.length + 1}');
                    if (name == null) return;
                    final id = await db.createPlaylist(name.isEmpty ? '我的播放清單 #${lists.length + 1}' : name);
                    lists = await db.playlists();
                    setState(() => ticked.add(id));
                  },
                ),
                for (final pl in lists)
                  CheckboxListTile(
                    value: ticked.contains(pl.id),
                    onChanged: (v) => setState(() => v == true ? ticked.add(pl.id) : ticked.remove(pl.id)),
                    secondary: ArtImage(pl.art, size: 44, icon: Icons.queue_music),
                    title: Text(pl.name),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    ),
  );
}

/// 「更改」 (1.20.9): which playlists a downloaded song goes into — one still
/// downloading gets them when it is done; a finished one is put into the
/// ticked ones and taken out of the others. The first one ticked is where
/// the next downloads go (for an hour, like picking it at the start).
Future<void> changeDownloadPlaylists(BuildContext context, DownloadTask task) async {
  final c = ProviderScope.containerOf(context, listen: false);
  final db = c.read(dbProvider);
  final svc = c.read(downloadServiceProvider);
  var song = await svc.songOf(task);
  final before = song != null ? await db.playlistsWith(song.id) : {if (task.playlistId != null) task.playlistId!, ...task.alsoInto};
  if (!context.mounted) return;
  final picked = await pickPlaylists(context, before);
  if (picked == null) return;
  final lists = await db.playlists();
  String? nameOf(int? id) => lists.where((p) => p.id == id).firstOrNull?.name;
  // Finished meanwhile: the song is there now.
  final had = song != null;
  song ??= await svc.songOf(task);
  if (song != null) {
    final now = had ? before : await db.playlistsWith(song.id);
    for (final id in picked) {
      if (!now.contains(id)) await db.addToPlaylist(id, [song]);
    }
    for (final id in now) {
      if (!picked.contains(id)) await db.removeTrackFromPlaylist(id, song.id);
    }
  } else {
    task.playlistId = picked.firstOrNull;
    task.playlistName = nameOf(task.playlistId);
    task.alsoInto
      ..clear()
      ..addAll(picked.skip(1));
  }
  final first = picked.firstOrNull;
  await db.setSetting(DownloadTarget.key, DownloadTarget(playlistId: first, name: nameOf(first), at: DateTime.now()).encode());
  if (!context.mounted) return;
  final done = song != null;
  final names = [for (final id in picked) '「${nameOf(id)}」'];
  toast(
      context,
      names.isEmpty
          ? (done ? '已從播放清單移除' : '完成後只加入音樂庫')
          : names.length <= 2
              ? '${done ? '已加入' : '完成後加入'}${names.join('、')}'
              : '${done ? '已加入' : '完成後加入'} ${names.length} 個播放清單');
}

/// 試聽 tracks (a short-lived audio address) and the song page each came
/// from, so 加入播放清單 and ♥ download the song instead of keeping the address.
final previewSources = <String, ({String url, String title})>{};

/// The song page behind a preview track, or null for other tracks.
({String url, String title})? previewSourceOf(String trackId) => previewSources[trackId];

/// ♥ or 加入播放清單 on a preview: asks first, then downloads the song
/// (liked, or into the playlist picked).
Future<void> downloadPreview(BuildContext context, ({String url, String title}) preview, {required bool like}) async {
  final ok = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => AlertDialog(
      title: Text(like ? '下載並加入已按讚的歌曲？' : '下載並加入播放清單？'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('下載')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  await startDownload(context, preview.url, title: preview.title, ask: !like, like: like, askPlaylist: !like);
}
