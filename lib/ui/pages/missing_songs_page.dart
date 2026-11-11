import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/missing_songs.dart';
import '../../services/network_check.dart';
import '../../services/online/ytmusic.dart';
import '../../services/song_matcher.dart';
import '../widgets/art_image.dart';
import '../widgets/cover_progress.dart';
import '../widgets/dialogs.dart';
import '../widgets/download_actions.dart';
import 'pick_replacement_page.dart';
import '../widgets/empty_state.dart';

/// Every placeholder with the playlists it sits in.
final missingSongsProvider = FutureProvider<List<(Track, List<String>)>>((ref) async {
  ref.watch(dbRevisionProvider);
  final app = ref.watch(dbProvider);
  final out = <(Track, List<String>)>[];
  for (final t in await MissingSongs.all(app)) {
    final rows = await app.db.rawQuery(
        'SELECT DISTINCT p.name AS name FROM playlist_tracks pt JOIN playlists p ON p.id = pt.playlist_id WHERE pt.track_id = ?', [t.id]);
    final liked = (await app.db.query('favorites', where: 'track_id = ?', whereArgs: [t.id])).isNotEmpty;
    if (rows.isEmpty && !liked) {
      // Removed from every list: nothing left to fill.
      await app.db.delete('tracks', where: 'id = ?', whereArgs: [t.id]);
      continue;
    }
    out.add((t, [...rows.map((r) => r['name'] as String), if (liked) '已按讚的歌曲']));
  }
  return out;
});

/// The search text for a missing song: cleaned title and first artist.
String linkQuery(Track t) {
  final artist = t.artist == '未知演出者' ? '' : SongMatcher.searchArtist(t.artist);
  return [SongMatcher.searchTitle(t.title, t.artist), artist].where((s) => s.isNotEmpty).join(' ');
}

/// 缺少的歌曲: songs listed in playlists but not on the device. A download
/// fills the place: automatic when YouTube Music has a sure match (same
/// artist, close title and length), otherwise picked by hand.
class MissingSongsPage extends ConsumerStatefulWidget {
  const MissingSongsPage({super.key});

  @override
  ConsumerState<MissingSongsPage> createState() => _MissingSongsPageState();
}

class _MissingSongsPageState extends ConsumerState<MissingSongsPage> {
  final _busy = <String>{};
  bool _all = false;

  /// 選取 mode: download, or remove, several songs at once.
  Set<String>? _picked;

  Future<void> _removePicked(List<Track> songs) async {
    final ids = _picked ?? const {};
    final chosen = songs.where((t) => ids.contains(t.id)).toList();
    if (chosen.isEmpty) return;
    if (!await confirmDelete(context, title: '移除 ${chosen.length} 首缺少的歌曲？', action: '移除')) return;
    final db = ref.read(dbProvider);
    for (final t in chosen) {
      await MissingSongs.remove(db, t.id);
    }
    if (!mounted) return;
    setState(() => _picked = null);
    toast(context, '已移除 ${chosen.length} 首');
  }

  /// Songs whose search found no sure match: picked by hand (選擇版本).
  final _unsure = <String, List<YtMusicSong>>{};

  /// The download started for each missing song (its progress on the cover).
  final _queued = <String, String>{};

  void _queue(Track t, YtMusicSong song) {
    _queued[t.id] = song.url;
    ref.read(downloadServiceProvider).add(song.url, format: ref.read(settingsProvider).ytFormat, title: t.title, art: t.art ?? song.artwork);
  }

  /// Searches one song: queued when the match is sure; otherwise kept for
  /// picking by hand. False when nothing was found or it is unsure.
  Future<bool> _download(Track t) async {
    setState(() => _busy.add(t.id));
    try {
      final results = await YtMusicSearch().search(linkQuery(t));
      final song = sureMatch(t.title, t.artist, t.durationMs, results);
      if (song != null) {
        _queue(t, song);
        _unsure.remove(t.id);
        return true;
      }
      if (results.isNotEmpty) _unsure[t.id] = results;
      return false;
    } catch (_) {
      return false;
    } finally {
      if (mounted) setState(() => _busy.remove(t.id));
    }
  }

  Future<void> _downloadAll(List<Track> songs) async {
    if (songs.isEmpty || !await acceptDownloadTerms(context) || !mounted) return;
    if (!await okToDownload(context, warn: ref.read(settingsProvider).wifiWarning) || !mounted) return;
    setState(() => _all = true);
    var queued = 0;
    try {
      for (final t in songs) {
        if (!mounted) break;
        if (await _download(t)) queued++;
      }
    } finally {
      if (mounted) setState(() => _all = false);
    }
    final left = songs.length - queued;
    if (mounted) toast(context, left == 0 ? '已加入下載' : '已加入下載 $queued 首，$left 首需要選擇');
  }

  Future<void> _downloadOne(Track t) async {
    if (!await acceptDownloadTerms(context) || !mounted) return;
    if (!await okToDownload(context, warn: ref.read(settingsProvider).wifiWarning) || !mounted) return;
    if (await _download(t)) {
      if (mounted) toast(context, '已加入下載');
    } else if (_unsure.containsKey(t.id)) {
      if (mounted) await _choose(t);
    } else if (mounted) {
      toast(context, '找不到「${t.title}」');
    }
  }

  /// 選擇版本: the search results for [t]; the one tapped is downloaded.
  Future<void> _choose(Track t) async {
    final results = _unsure[t.id] ?? const <YtMusicSong>[];
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final song = await showModalBottomSheet<YtMusicSong>(
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
    if (song == null || !mounted) return;
    _queue(t, song);
    setState(() => _unsure.remove(t.id));
    toast(context, '已加入下載');
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(missingSongsProvider).value ?? const [];
    final songs = [for (final (t, _) in list) t];
    return Scaffold(
      appBar: AppBar(title: Text(_picked == null ? '缺少的歌曲（${list.length}）' : '已選 ${_picked!.length} 首'), actions: [
        if (_picked != null) ...[
          IconButton(
            tooltip: '下載',
            icon: const Icon(Icons.download_rounded),
            onPressed: _picked!.isEmpty || _all ? null : () => _downloadAll([for (final t in songs) if (_picked!.contains(t.id)) t]),
          ),
          IconButton(
            tooltip: '移除',
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: _picked!.isEmpty ? null : () => _removePicked(songs),
          ),
          IconButton(tooltip: '取消選取', icon: const Icon(Icons.close), onPressed: () => setState(() => _picked = null)),
        ] else if (list.isNotEmpty)
          IconButton(tooltip: '選取', icon: const Icon(Icons.checklist), onPressed: () => setState(() => _picked = {})),
      ]),
      body: list.isEmpty
          ? const EmptyState(icon: Icons.check_circle_outline_rounded, title: '沒有缺少的歌曲')
          : ListView(children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  icon: _all ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.download_rounded),
                  label: const Text('全部下載'),
                  onPressed: _all ? null : () => _downloadAll(songs),
                ),
              ),
              for (final (t, playlists) in list) _row(t, playlists),
            ]),
    );
  }

  Widget _row(Track t, List<String> playlists) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final picked = _picked;
    final subtitle = Text('${t.artist} • ${playlists.join('、')}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: muted));
    if (picked != null) {
      return CheckboxListTile(
        value: picked.contains(t.id),
        onChanged: (v) => setState(() => v == true ? picked.add(t.id) : picked.remove(t.id)),
        title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: subtitle,
      );
    }
    ref.watch(downloadsProvider);
    final url = _queued[t.id];
    final task = url == null ? null : ref.read(downloadServiceProvider).taskFor(url);
    return ListTile(
      leading: CoverProgress(art: t.art, task: task, size: 44),
      title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle,
      trailing: _busy.contains(t.id)
          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
          : Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                tooltip: '從音樂庫選擇',
                icon: const Icon(Icons.library_music_outlined),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PickReplacementPage(missing: t))),
              ),
              _unsure.containsKey(t.id)
                  ? TextButton(onPressed: () => _choose(t), child: const Text('選擇'))
                  : IconButton(tooltip: '下載', icon: const Icon(Icons.download_rounded), onPressed: () => _downloadOne(t)),
            ]),
    );
  }
}
