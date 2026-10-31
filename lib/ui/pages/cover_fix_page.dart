import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/cover_finder.dart';
import '../../services/song_matcher.dart';
import '../../services/tag_editor.dart';
import '../widgets/art_image.dart';
import '../widgets/dialogs.dart';
import '../widgets/lookup_confirm.dart';

/// 找封面 for [tracks] (the library, a playlist): asks first, then opens
/// [CoverFixPage] with the songs worth looking up.
Future<void> findCovers(BuildContext context, WidgetRef ref, List<Track> tracks, {bool small = false}) async {
  await CoverFinder.loadSize(ref.read(dbProvider));
  final want = tracks.where((t) => CoverFinder.wantsCover(t) || (small && CoverFinder.smallCover(t))).toList();
  if (!context.mounted) return;
  if (want.isEmpty) {
    toast(context, '沒有需要找封面的歌曲');
    return;
  }
  final list = await confirmLookup(context, ref,
      kind: 'cover',
      tracks: want,
      title: (n) => '替 $n 首找封面？',
      message: (n) => 'iTunes 每分鐘大約只能查 20 次，大約需要 ${(n * 3 / 60).ceil()} 分鐘。找完會先讓你預覽，確認後才更換。');
  if (list != null && context.mounted) {
    await Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => CoverFixPage(tracks: list)));
  }
}

/// 補封面: looks up official covers for [tracks], shows old and new side by
/// side, and replaces the ticked ones (into the file when its format allows).
class CoverFixPage extends ConsumerStatefulWidget {
  const CoverFixPage({super.key, required this.tracks});
  final List<Track> tracks;

  @override
  ConsumerState<CoverFixPage> createState() => _CoverFixPageState();
}

class _CoverFixPageState extends ConsumerState<CoverFixPage> {
  final _hits = <String, CoverHit?>{};
  final _ticked = <String>{};
  bool _searching = true, _applying = false, _stop = false, _paused = false;
  int _done = 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _stop = true;
    super.dispose();
  }

  Future<void> _run() async {
    final finder = CoverFinder(ref.read(iTunesSearchProvider), japaneseLyrics: ref.read(lyricsServiceProvider).japaneseLyrics);
    final db = ref.read(dbProvider);
    await finder.findAll(widget.tracks, (t, hit) {
      db.setLookupMiss('cover', t.id, hit == null);
      if (!mounted) return;
      setState(() {
        _hits[t.id] = hit;
        _done++;
        if (hit?.level == MatchLevel.sure) _ticked.add(t.id);
      });
    }, cancelled: () => _stop || !mounted, paused: () => _paused);
    if (mounted) setState(() => _searching = false);
  }

  Future<void> _apply() async {
    final chosen = [for (final t in widget.tracks) if (_ticked.contains(t.id) && _hits[t.id] != null) _hits[t.id]!];
    if (chosen.isEmpty) return;
    setState(() => _applying = true);
    final finder = CoverFinder(ref.read(iTunesSearchProvider));
    final db = ref.read(dbProvider);
    final handler = ref.read(audioHandlerProvider);
    var ok = 0, failed = 0;
    for (final h in chosen) {
      try {
        final bytes = await finder.download(h.url);
        final t = h.track;
        if (canWriteTags(t.uri)) {
          await writeTags(t.uri, TagEdit(title: t.title, artist: t.artist, album: t.album, cover: bytes));
        }
        final art = await ref.read(scannerProvider).storeArt(bytes, 'image/jpeg');
        final updated = Track(
          id: t.id,
          uri: t.uri,
          title: t.title,
          artist: t.artist,
          album: t.album,
          durationMs: t.durationMs,
          art: art,
          source: t.source,
          trackNo: t.trackNo,
          addedAt: t.addedAt,
        );
        await db.updateTrackInfo(updated);
        handler.updateTrackInfo(updated);
        ok++;
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() => _applying = false);
    toast(context, failed == 0 ? '已更換 $ok 首的封面' : '已更換 $ok 首，$failed 首失敗');
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final found = _hits.values.whereType<CoverHit>().length;
    return Scaffold(
      appBar: AppBar(
        title: Text(_searching
            ? '${_stop ? '停止中' : _paused ? '已暫停' : '找封面中'} $_done / ${widget.tracks.length}'
            : '找到 $found 首的封面'),
        actions: [
          FilledButton(
            onPressed: _applying || _ticked.isEmpty ? null : _apply,
            child: Text(_applying ? '更換中…' : '更換 ${_ticked.length} 首'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: ListView(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text('封面來自 iTunes。勾選的會換成正式的正方形封面；MP3、M4A、FLAC 會寫進檔案，其他格式只在 OuOPlayer 裡更換。'
              '「可能是」的結果預設不勾，請確認是同一張專輯再勾。',
              style: TextStyle(color: muted, fontSize: 13)),
        ),
        if (_searching) ...[
          LinearProgressIndicator(value: _paused ? _done / widget.tracks.length : null),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: LookupControls(
              paused: _paused,
              stopping: _stop,
              onPause: () => setState(() => _paused = !_paused),
              onStop: () => setState(() => _stop = true),
            ),
          ),
        ],
        for (final t in widget.tracks)
          if (_hits.containsKey(t.id)) _row(t, _hits[t.id]),
      ]),
    );
  }

  Widget _row(Track t, CoverHit? hit) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return CheckboxListTile(
      value: _ticked.contains(t.id),
      onChanged: hit == null ? null : (v) => setState(() => v == true ? _ticked.add(t.id) : _ticked.remove(t.id)),
      secondary: SizedBox(
        width: 112,
        child: Row(children: [
          ArtImage(t.art, size: 48),
          const Icon(Icons.arrow_forward, size: 16),
          hit == null ? const SizedBox(width: 48, child: Icon(Icons.image_not_supported_outlined)) : ArtImage(hit.url, size: 48),
        ]),
      ),
      title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        hit == null
            ? '找不到對得上的封面'
            : '${hit.level == MatchLevel.sure ? '' : '可能是：'}${hit.song.album} • ${hit.song.artist}',
        maxLines: 2,
        style: TextStyle(color: muted),
      ),
    );
  }
}
