import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/lyrics/lyrics_service.dart';
import '../widgets/art_image.dart';
import '../widgets/lookup_confirm.dart';
import '../widgets/lyrics_view.dart';

/// Songs whose lyrics a batch can look up (not online streams or podcasts).
List<Track> lyricsCandidates(Iterable<Track> tracks) => [
      for (final t in tracks)
        if (!t.isRemote && t.uri.isNotEmpty && t.source != TrackSource.podcast && t.source != TrackSource.missing) t,
    ];

/// Asks first, then opens the batch page.
Future<void> findLyrics(BuildContext context, WidgetRef ref, List<Track> tracks, {required String title}) async {
  final all = lyricsCandidates(tracks);
  if (all.isEmpty) return;
  final list = await confirmLookup(context, ref,
      kind: 'lyrics',
      tracks: all,
      title: (n) => '替 $n 首找歌詞？',
      message: (_) => '已經有歌詞的歌會略過。其他的會從 LRCLIB（免費歌詞資料庫）一首一首查，'
          '只會送出歌名、歌手、專輯和長度。每首大約 1 秒，找到的歌詞存在手機上。');
  if (list != null && context.mounted) {
    await Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => LyricsBatchPage(tracks: list, title: title)));
  }
}

/// 找歌詞: goes through [tracks] one by one, skipping songs that already have
/// lyrics; the ones LRCLIB doesn't know are listed for a manual search.
class LyricsBatchPage extends ConsumerStatefulWidget {
  const LyricsBatchPage({super.key, required this.tracks, required this.title});
  final List<Track> tracks;
  final String title;

  @override
  ConsumerState<LyricsBatchPage> createState() => _LyricsBatchPageState();
}

class _LyricsBatchPageState extends ConsumerState<LyricsBatchPage> {
  int _done = 0, _found = 0, _had = 0;
  final _missing = <Track>[];
  bool _stop = false, _finished = false, _paused = false;
  String? _current, _error;

  /// Songs being tried again after LRCLIB was busy.
  int _retrying = 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final lyrics = ref.read(lyricsServiceProvider);
    // Songs LRCLIB was too busy for get one more try at the end; only a
    // real "no lyrics" puts a song on the not-found list.
    final later = <Track>[];
    var failures = 0;
    final db = ref.read(dbProvider);
    Future<bool> one(Track t, {required bool lastTry}) async {
      while (_paused && !_stop && mounted) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
      if (_stop || !mounted) return false;
      setState(() => _current = t.title);
      try {
        if (await lyrics.hasLyrics(t)) {
          _had++;
          await db.setLookupMiss('lyrics', t.id, false);
        } else {
          final ok = await lyrics.fetchOnline(t);
          ok ? _found++ : _missing.add(t);
          await db.setLookupMiss('lyrics', t.id, !ok);
          failures = 0;
          await Future.delayed(const Duration(milliseconds: 1500));
        }
      } on DioException catch (e) {
        if (!LyricsService.isTemporary(e)) {
          _missing.add(t);
          await db.setLookupMiss('lyrics', t.id, true);
        } else if (lastTry) {
          _missing.add(t);
        } else {
          later.add(t);
        }
        // Offline or LRCLIB down: stop instead of failing every song.
        if (LyricsService.isTemporary(e) && ++failures >= 3) {
          _error = '連不上 LRCLIB，已暫停。請檢查網路後再試一次';
          return false;
        }
        await Future.delayed(const Duration(seconds: 5));
      } catch (_) {
        _missing.add(t);
      }
      return true;
    }

    for (final t in widget.tracks) {
      if (_stop || !mounted) break;
      if (!await one(t, lastTry: false)) break;
      if (mounted) setState(() => _done++);
    }
    if (later.isNotEmpty && !_stop && _error == null && mounted) {
      setState(() => _retrying = later.length);
      await Future.delayed(const Duration(seconds: 20));
      for (final t in later) {
        if (_stop || !mounted) break;
        if (!await one(t, lastTry: true)) break;
      }
    }
    ref.invalidate(lyricsProvider);
    if (mounted) setState(() => _finished = true);
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.tracks.length;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final running = !_finished;
    return PopScope(
      canPop: !running,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _stop = true);
      },
      child: Scaffold(
        appBar: AppBar(title: Text('找歌詞：${widget.title}')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          LinearProgressIndicator(value: total == 0 ? 1 : _done / total),
          const SizedBox(height: 12),
          Text(
              running
                  ? (_stop
                      ? '停止中…'
                      : _paused
                      ? '已暫停：$_done / $total'
                      : _done >= total && _retrying > 0
                          ? 'LRCLIB 剛剛太忙，重試 $_retrying 首：${_current ?? ''}'
                          : '$_done / $total：${_current ?? ''}')
                  : '完成：$_done / $total',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('找到 $_found 首 • 本來就有 $_had 首 • 找不到 ${_missing.length} 首', style: TextStyle(color: muted)),
          if (_error != null) Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
          const SizedBox(height: 12),
          if (running)
            Align(
              alignment: Alignment.centerLeft,
              child: LookupControls(
                paused: _paused,
                stopping: _stop,
                onPause: () => setState(() => _paused = !_paused),
                onStop: () => setState(() => _stop = true),
              ),
            ),
          if (_missing.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('找不到的歌（點一首可以手動搜尋）', style: Theme.of(context).textTheme.titleSmall),
            for (final t in _missing)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: ArtImage(t.art, size: 44),
                title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(t.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: muted)),
                trailing: const Icon(Icons.search),
                onTap: () async {
                  // Found by hand: off the list.
                  if (await showLyricsSearch(context, ref, t) && mounted) {
                    await ref.read(dbProvider).setLookupMiss('lyrics', t.id, false);
                    setState(() {
                      _missing.remove(t);
                      _found++;
                    });
                  }
                },
              ),
          ],
        ]),
      ),
    );
  }
}
