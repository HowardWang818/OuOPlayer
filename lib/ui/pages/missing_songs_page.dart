import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/missing_songs.dart';
import '../../services/online/youtube_link.dart';
import '../../services/song_matcher.dart';
import '../widgets/dialogs.dart';
import '../widgets/links.dart';
import 'pick_replacement_page.dart';
import 'youtube_key_guide_page.dart';
import '../../config/device_words.dart';

/// Many songs missing: Soundiiz moves whole playlists to YouTube Music
/// in one go, faster than looking songs up one by one (and no API quota).
bool suggestSoundiiz(int missing, int total) => missing >= soundiizMinMissing || (total > 0 && missing / total >= 0.5 && missing >= 10);
const soundiizMinMissing = 30;
const soundiizUrl = 'https://soundiiz.com/';

class SoundiizTip extends StatelessWidget {
  const SoundiizTip({super.key});

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(top: 8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('缺少的歌很多', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('想在 YouTube Music 上聽這些歌單的話，建議用 Soundiiz（第三方網站）把 Spotify 歌單整份轉到 YouTube Music，'
                '比在這裡一首一首取得連結快，也不會用掉你的 YouTube API 額度。'),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.open_in_new),
                label: const Text('開啟 Soundiiz'),
                onPressed: () => openExternal(context, soundiizUrl),
              ),
            ),
          ]),
        ),
      );
}

/// A YouTube Music link found for a missing song (kept in settings).
class FoundLink {
  const FoundLink(this.url, this.title, this.channel, this.official);
  final String url, title, channel;
  final bool official;

  Map<String, dynamic> toJson() => {'url': url, 'title': title, 'channel': channel, 'official': official};
  static FoundLink? fromJson(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final j = jsonDecode(s) as Map;
      return FoundLink(j['url'] as String, j['title'] as String? ?? '', j['channel'] as String? ?? '', j['official'] == true);
    } catch (_) {
      return null;
    }
  }
}

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

/// 「歌名 - 歌手」 lines with their links, for 複製全部連結.
String linksText(List<(Track, FoundLink)> found) => [for (final (t, l) in found) '${t.title} - ${t.artist}：${l.url}'].join('\n');

/// The YouTube Data API allows about 100 searches a day (100 units each).
const dailySearches = 100;
const maxSearchesPerRun = 50;

/// What share of the day's free searches [n] searches use.
int quotaPercent(int n) => (n * 100 / dailySearches).ceil().clamp(0, 100);

/// The search text for a missing song: cleaned title and first artist.
String linkQuery(Track t) {
  final artist = t.artist == '未知演出者' ? '' : SongMatcher.searchArtist(t.artist);
  return [SongMatcher.searchTitle(t.title, t.artist), artist].where((s) => s.isNotEmpty).join(' ');
}

/// 缺少的歌曲: songs listed in playlists but not on the device. Links come
/// from the user's own YouTube Data API key; nothing is downloaded.
class MissingSongsPage extends ConsumerStatefulWidget {
  const MissingSongsPage({super.key});

  @override
  ConsumerState<MissingSongsPage> createState() => _MissingSongsPageState();
}

class _MissingSongsPageState extends ConsumerState<MissingSongsPage> {
  final _busy = <String>{};
  bool _all = false;

  /// 選取 mode: get links for, or remove, several songs at once.
  Set<String>? _picked;

  Future<void> _removePicked(List<Track> songs) async {
    final ids = _picked ?? const {};
    final chosen = songs.where((t) => ids.contains(t.id)).toList();
    if (chosen.isEmpty) return;
    if (!await confirmDelete(context,
        title: '移除 ${chosen.length} 首缺少的歌曲？', message: '會從所有播放清單和已按讚的歌曲中移除這些灰色的歌。', action: '移除')) {
      return;
    }
    final db = ref.read(dbProvider);
    for (final t in chosen) {
      await MissingSongs.remove(db, t.id);
    }
    if (!mounted) return;
    setState(() => _picked = null);
    toast(context, '已移除 ${chosen.length} 首');
  }

  FoundLink? _link(String id) => FoundLink.fromJson(ref.read(sortProvider('ytlink_$id')));

  Future<bool> _ensureKey() async {
    if (ref.read(settingsProvider).youtubeApiKey.isNotEmpty) return true;
    await showDialog(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        title: const Text('需要 YouTube 金鑰'),
        content: const Text('「取得 YouTube Music 連結」需要一組免費的 YouTube Data API 金鑰，申請約 5 分鐘。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const YouTubeKeyGuidePage()));
            },
            child: const Text('查看申請步驟'),
          ),
        ],
      ),
    );
    return false;
  }

  /// Looks one song up; false when the day's quota ran out.
  Future<bool> _lookup(Track t) async {
    setState(() => _busy.add(t.id));
    try {
      final v = await ref.read(youTubeLinkFinderProvider).find(ref.read(settingsProvider).youtubeApiKey, linkQuery(t));
      if (v != null) {
        // Saved per song (the settings' sort map holds free-form keys).
        ref.read(sortProvider('ytlink_${t.id}').notifier).set(jsonEncode(FoundLink(v.url, v.title, v.channel, v.isOfficialAudio).toJson()));
      } else if (mounted) {
        toast(context, '找不到「${t.title}」');
      }
      return true;
    } on YouTubeLinkException catch (e) {
      if (mounted) toast(context, e.message);
      return !e.message.contains('額度');
    } finally {
      if (mounted) setState(() => _busy.remove(t.id));
    }
  }

  Future<void> _lookupAll(List<Track> songs) async {
    final todo = songs.where((t) => _link(t.id) == null).take(maxSearchesPerRun).toList();
    if (todo.isEmpty || !await _ensureKey() || !mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        title: Text('取得 ${todo.length} 首的連結？'),
        content: Text('大約會用掉今天免費額度的 ${quotaPercent(todo.length)}%（每天約可查 $dailySearches 首，隔天自動恢復）。'
            '${songs.length - todo.length > maxSearchesPerRun ? '\n一次最多 $maxSearchesPerRun 首，剩下的可以再按一次。' : ''}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('開始')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _all = true);
    try {
      for (final t in todo) {
        if (!mounted || !await _lookup(t)) break;
      }
    } finally {
      if (mounted) setState(() => _all = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(missingSongsProvider).value ?? const [];
    for (final (t, _) in list) {
      ref.watch(sortProvider('ytlink_${t.id}'));
    }
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final found = [for (final (t, _) in list) if (_link(t.id) != null) (t, _link(t.id)!)];
    return Scaffold(
      appBar: AppBar(title: Text(_picked == null ? '缺少的歌曲（${list.length}）' : '已選 ${_picked!.length} 首'), actions: [
        if (_picked != null) ...[
          IconButton(
            tooltip: '取得選取歌曲的連結',
            icon: const Icon(Icons.link),
            onPressed: _picked!.isEmpty || _all ? null : () => _lookupAll([for (final (t, _) in list) if (_picked!.contains(t.id)) t]),
          ),
          IconButton(
            tooltip: '移除選取的歌曲',
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: _picked!.isEmpty ? null : () => _removePicked([for (final (t, _) in list) t]),
          ),
          IconButton(tooltip: '取消選取', icon: const Icon(Icons.close), onPressed: () => setState(() => _picked = null)),
        ] else if (list.isNotEmpty)
          IconButton(tooltip: '選取', icon: const Icon(Icons.checklist), onPressed: () => setState(() => _picked = {})),
        if (found.isNotEmpty)
          IconButton(
            tooltip: '複製全部連結',
            icon: const Icon(Icons.copy_all),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: linksText(found)));
              if (context.mounted) toast(context, '已複製 ${found.length} 個連結');
            },
          ),
      ]),
      body: list.isEmpty
          ? Center(child: Text('沒有缺少的歌曲', style: TextStyle(color: muted)))
          : ListView(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text('這些歌在播放清單裡，但$thisDevice上還沒有。之後下載或加入音樂庫時，會自動補回原本的位置。連結只是方便你找，不會自動下載。',
                    style: TextStyle(color: muted, fontSize: 13)),
              ),
              if (list.length >= soundiizMinMissing) const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: SoundiizTip()),
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  icon: _all ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.link),
                  label: const Text('全部取得 YouTube Music 連結'),
                  onPressed: _all ? null : () => _lookupAll([for (final (t, _) in list) t]),
                ),
              ),
              for (final (t, playlists) in list) _row(t, playlists),
            ]),
    );
  }

  Widget _row(Track t, List<String> playlists) {
    final link = FoundLink.fromJson(ref.watch(sortProvider('ytlink_${t.id}')));
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final picked = _picked;
    if (picked != null) {
      return CheckboxListTile(
        value: picked.contains(t.id),
        onChanged: (v) => setState(() => v == true ? picked.add(t.id) : picked.remove(t.id)),
        title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${t.artist} • ${playlists.join('、')}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: muted)),
      );
    }
    return ListTile(
      leading: IconButton(
        tooltip: '從音樂庫選擇這首歌',
        icon: const Icon(Icons.library_music_outlined),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PickReplacementPage(missing: t))),
      ),
      title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          '${t.artist} • ${playlists.join('、')}',
          if (link != null) '${link.official ? '官方音源' : '可能是 MV／翻唱'}：${link.title}',
        ].join('\n'),
        maxLines: 3,
        style: TextStyle(color: muted),
      ),
      isThreeLine: link != null,
      trailing: _busy.contains(t.id)
          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
          : link == null
              ? TextButton(onPressed: () async => await _ensureKey() ? _lookup(t) : null, child: const Text('取得連結'))
              : PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'pick') {
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => PickReplacementPage(missing: t)));
                    } else if (v == 'copy') {
                      await Clipboard.setData(ClipboardData(text: link.url));
                      if (mounted) toast(context, '已複製連結');
                    } else if (v == 'open') {
                      await openExternal(context, link.url);
                    } else if (v == 'again') {
                      if (await _ensureKey()) await _lookup(t);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'pick', child: Text('從音樂庫選擇這首歌')),
                    PopupMenuItem(value: 'copy', child: Text('複製連結')),
                    PopupMenuItem(value: 'open', child: Text('在 YouTube Music 開啟')),
                    PopupMenuItem(value: 'again', child: Text('重新查詢')),
                  ],
                ),
    );
  }
}
