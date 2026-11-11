import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/network_check.dart';
import '../../services/online/ytmusic.dart';
import '../pages/missing_songs_page.dart' show linkQuery;
import 'art_image.dart';
import 'dialogs.dart';
import 'download_actions.dart';

/// What a search found for a missing song: [sure] is downloaded on its own;
/// otherwise [results] are offered to pick from.
typedef MissingFind = ({YtMusicSong? sure, List<YtMusicSong> results});

Future<MissingFind> findMissing(Track t) async {
  final results = await YtMusicSearch().search(linkQuery(t));
  return (sure: sureMatch(t.title, t.artist, t.durationMs, results), results: results);
}

/// Queues [song] for the missing song [t] (its place fills itself once the
/// file is in the library).
void queueMissing(ProviderContainer c, Track t, YtMusicSong song) =>
    c.read(downloadServiceProvider).add(song.url, format: c.read(settingsProvider).ytFormat, title: t.title, art: t.art ?? song.artwork);

/// 選擇版本: the search results for [t]; the one tapped, or null.
Future<YtMusicSong?> pickVersion(BuildContext context, Track t, List<YtMusicSong> results) {
  final muted = Theme.of(context).colorScheme.onSurfaceVariant;
  return showModalBottomSheet<YtMusicSong>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
        child: ListView(shrinkWrap: true, children: [
          ListTile(title: Text(t.title, style: const TextStyle(fontWeight: FontWeight.w600)), subtitle: Text(t.artist)),
          const Divider(),
          for (final r in results)
            ListTile(
              leading: ArtImage(r.artwork, size: 44),
              title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                  [r.artist, if (r.album != null) r.album!, if (r.durationMs != null) formatDuration(Duration(milliseconds: r.durationMs!))].join(' • '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: muted)),
              onTap: () => Navigator.pop(ctx, r),
            ),
        ]),
      ),
    ),
  );
}

/// 下載 on one missing song: a sure match downloads at once, otherwise the
/// results are offered to pick from.
Future<void> downloadMissingSong(BuildContext context, Track t) async {
  final c = ProviderScope.containerOf(context, listen: false);
  if (!await acceptDownloadTerms(context) || !context.mounted) return;
  if (!await okToDownload(context, warn: c.read(settingsProvider).wifiWarning) || !context.mounted) return;
  final MissingFind found;
  try {
    found = await findMissing(t);
  } catch (_) {
    if (context.mounted) toast(context, '無網路連線');
    return;
  }
  if (!context.mounted) return;
  var song = found.sure;
  if (song == null && found.results.isNotEmpty) song = await pickVersion(context, t, found.results);
  if (!context.mounted) return;
  if (song == null) {
    if (found.results.isEmpty) toast(context, '找不到「${t.title}」');
    return;
  }
  queueMissing(c, t, song);
  toast(context, '已加入下載');
}

/// 下載缺少的 N 首: sure matches download; the count left to pick by hand
/// (on 缺少的歌曲) is returned.
Future<int?> downloadMissingSongs(BuildContext context, List<Track> songs) async {
  final c = ProviderScope.containerOf(context, listen: false);
  if (songs.isEmpty || !await acceptDownloadTerms(context) || !context.mounted) return null;
  if (!await okToDownload(context, warn: c.read(settingsProvider).wifiWarning) || !context.mounted) return null;
  toast(context, '正在搜尋 ${songs.length} 首');
  var queued = 0;
  for (final t in songs) {
    try {
      final found = await findMissing(t);
      if (found.sure != null) {
        queueMissing(c, t, found.sure!);
        queued++;
      }
    } catch (_) {}
  }
  final left = songs.length - queued;
  if (context.mounted) toast(context, left == 0 ? '已加入下載' : '已加入下載 $queued 首，$left 首需要在「缺少的歌曲」選擇');
  return left;
}
