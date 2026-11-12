import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
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
  c.read(downloadServiceProvider).add(url, format: c.read(settingsProvider).ytFormat, title: title, artist: artist, album: album, playlistId: target?.playlistId, playlistName: target?.name, like: like, art: art);
  if (context.mounted) {
    toast(context, like ? '已加入下載，完成後加入已按讚的歌曲' : target?.name == null ? '已加入下載' : '已加入下載，完成後加入「${target!.name}」');
  }
  return true;
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
