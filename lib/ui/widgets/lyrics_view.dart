import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/lyrics/lrc.dart';
import '../../services/lyrics/lyrics_service.dart';
import '../../theme/app_theme.dart';
import 'dialogs.dart';

/// Lyrics of the current song: synced ones follow playback (current line
/// lit, tap a line to jump there), plain ones just scroll.
class LyricsView extends ConsumerWidget {
  const LyricsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    if (track == null) return const SizedBox.shrink();
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final lyrics = ref.watch(lyricsProvider(LyricsKey(track)));
    return lyrics.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _Empty(
          track: track,
          retry: true,
          message: e is DioException && LyricsService.isTemporary(e)
              ? 'LRCLIB 暫時忙碌或連線逾時，請稍後再試'
              : e is DioException
                  ? '查詢歌詞失敗${e.response?.statusCode != null ? '（HTTP ${e.response!.statusCode}）' : '，請檢查網路'}'
                  : '查詢歌詞失敗：$e'),
      data: (l) => l == null || l.isEmpty
          ? _Empty(
              track: track,
              retry: true,
              message: ref.watch(settingsProvider.select((s) => s.lyricsOnline)) ? '找不到歌詞' : '找不到歌詞（自動上網找歌詞已關閉）')
          : Column(children: [
              Expanded(child: l.synced ? _SyncedLyrics(lyrics: l) : _PlainLyrics(lyrics: l)),
              Row(children: [
                Expanded(child: Text('來源：${l.source}${l.synced ? '' : '（未同步）'}', style: TextStyle(fontSize: 12, color: muted))),
                if (l.source == 'LRCLIB')
                  TextButton(onPressed: () => refreshLyrics(ref, track), child: const Text('重新查詢')),
                TextButton(onPressed: () => showLyricsSearch(context, ref, track), child: const Text('不對？手動搜尋')),
              ]),
            ]),
    );
  }
}

class _Empty extends ConsumerWidget {
  const _Empty({required this.track, required this.message, this.retry = false});
  final Track track;
  final String message;
  final bool retry;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.lyrics_outlined, size: 48),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: [
            if (retry)
              OutlinedButton.icon(
                onPressed: () => refreshLyrics(ref, track),
                icon: const Icon(Icons.refresh),
                label: const Text('重新查詢'),
              ),
            OutlinedButton.icon(
              onPressed: () => showLyricsSearch(context, ref, track),
              icon: const Icon(Icons.search),
              label: const Text('手動搜尋'),
            ),
          ]),
        ]),
      );
}

class _PlainLyrics extends StatelessWidget {
  const _PlainLyrics({required this.lyrics});
  final Lyrics lyrics;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          for (final l in lyrics.lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(l.text, style: const TextStyle(fontSize: 18, height: 1.4)),
            ),
        ],
      );
}

class _SyncedLyrics extends ConsumerStatefulWidget {
  const _SyncedLyrics({required this.lyrics});
  final Lyrics lyrics;

  @override
  ConsumerState<_SyncedLyrics> createState() => _SyncedLyricsState();
}

class _SyncedLyricsState extends ConsumerState<_SyncedLyrics> {
  final _keys = <int, GlobalKey>{};
  int _shown = -2;

  GlobalKey _key(int i) => _keys.putIfAbsent(i, GlobalKey.new);

  void _follow(int i) {
    if (i == _shown) return;
    _shown = i;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _key(i < 0 ? 0 : i).currentContext;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(ctx, alignment: 0.4, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final pos = ref.watch(positionProvider).value ?? Duration.zero;
    final current = widget.lyrics.indexAt(pos);
    _follow(current);
    final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.45);
    final player = ref.read(audioHandlerProvider);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 120),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var i = 0; i < widget.lyrics.lines.length; i++)
          InkWell(
            key: _key(i),
            borderRadius: BorderRadius.circular(6),
            onTap: () => player.seek(widget.lyrics.lines[i].time!),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: TextStyle(
                  fontSize: 22,
                  height: 1.3,
                  fontWeight: FontWeight.bold,
                  color: i == current ? AppColors.accent : muted,
                ),
                child: Text(widget.lyrics.lines[i].text.isEmpty ? '♪' : widget.lyrics.lines[i].text),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Forgets the saved LRCLIB result (or "not found") and asks again.
Future<void> refreshLyrics(WidgetRef ref, Track track) async {
  await ref.read(lyricsServiceProvider).forget(track);
  ref.invalidate(lyricsProvider(LyricsKey(track)));
}

/// Search LRCLIB with an editable title/artist and pick the right lyrics.
Future<void> showLyricsSearch(BuildContext context, WidgetRef ref, Track track) async {
  final title = TextEditingController(text: track.title.replaceAll('（試聽）', '').trim());
  final artist = TextEditingController(text: track.artist == '未知演出者' ? '' : track.artist);
  final service = ref.read(lyricsServiceProvider);
  final picked = await showDialog<LrclibResult>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) {
      List<LrclibResult>? results;
      String? error;
      var busy = false;
      return StatefulBuilder(builder: (ctx, setState) {
        Future<void> run() async {
          setState(() {
            busy = true;
            error = null;
          });
          try {
            results = await service.search(title.text.trim(), artist.text.trim());
          } catch (e) {
            error = e is DioException && LyricsService.isTemporary(e)
                ? 'LRCLIB 暫時忙碌或連線逾時，請稍後再按「搜尋」'
                : e is DioException
                    ? '無法連線到 LRCLIB，請檢查網路'
                    : '$e';
          }
          if (ctx.mounted) setState(() => busy = false);
        }

        return AlertDialog(
          title: const Text('搜尋歌詞'),
          content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: title, decoration: const InputDecoration(labelText: '歌名')),
              TextField(controller: artist, decoration: const InputDecoration(labelText: '歌手（可空白）'), onSubmitted: (_) => run()),
              const SizedBox(height: 12),
              if (busy)
                const Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator())
              else if (error != null)
                Text(error!)
              else if (results != null && results!.isEmpty)
                const Text('沒有找到，試試只填歌名，或換成原文歌名')
              else if (results != null)
                Flexible(
                  child: ListView(shrinkWrap: true, children: [
                    for (final r in results!)
                      ListTile(
                        title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [r.artist, if (r.album.isNotEmpty) r.album, if (r.durationSec != null) '${r.durationSec! ~/ 60}:${(r.durationSec! % 60).toString().padLeft(2, '0')}', (r.synced ?? '').isNotEmpty ? '同步' : '純文字']
                              .join(' • '),
                          maxLines: 2,
                        ),
                        onTap: () => Navigator.pop(ctx, r),
                      ),
                  ]),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(onPressed: busy ? null : run, child: const Text('搜尋')),
          ],
        );
      });
    },
  );
  if (picked == null) return;
  await service.choose(track, picked);
  ref.invalidate(lyricsProvider(LyricsKey(track)));
  if (context.mounted) toast(context, '已套用歌詞');
}
