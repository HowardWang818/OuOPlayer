import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/native_names.dart';
import '../widgets/dialogs.dart';
import '../widgets/lookup_confirm.dart';

/// 找原文歌名 for [tracks] (the library, a playlist, a selection): asks
/// first, then opens [NativeNamePage] with the songs named in Latin letters.
Future<void> findNativeNames(BuildContext context, WidgetRef ref, List<Track> tracks) async {
  final want = tracks.where(NativeNames.wants).toList();
  if (want.isEmpty) {
    toast(context, '沒有歌名是羅馬拼音或英文的歌曲');
    return;
  }
  final list = await confirmLookup(context, ref,
      // 'original' (v1.4.0): songs only checked for Japanese names before are looked up again.
      kind: 'original',
      tracks: want,
      title: (n) => '替 $n 首找原文歌名？',
      message: (n) => '從 iTunes 日本和台灣查歌名、歌手和專輯的日文或中文原名（只會送出歌名和歌手）；歌名括號裡已經有原文的直接改用。'
          'iTunes 每分鐘大約只能查 20 次，大約需要 ${(n * 3 / 60).ceil()} 分鐘。找完會先讓你預覽，確認後才更改。');
  if (list != null && context.mounted) {
    await Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => NativeNamePage(tracks: list)));
  }
}

/// Looks up the Japanese names of [tracks], shows old and new, and renames
/// the ticked ones (into the file when its format allows).
class NativeNamePage extends ConsumerStatefulWidget {
  const NativeNamePage({super.key, required this.tracks});
  final List<Track> tracks;

  @override
  ConsumerState<NativeNamePage> createState() => _NativeNamePageState();
}

class _NativeNamePageState extends ConsumerState<NativeNamePage> {
  final _hits = <String, NativeName?>{};
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
    final names = ref.read(nativeNamesProvider);
    final db = ref.read(dbProvider);
    for (final t in widget.tracks) {
      while (_paused && !_stop && mounted) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
      if (_stop || !mounted) break;
      NativeName? hit;
      try {
        hit = await names.find(t);
        await db.setLookupMiss('original', t.id, hit == null);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _hits[t.id] = hit;
        _done++;
        if (hit != null) _ticked.add(t.id);
      });
    }
    if (mounted) setState(() => _searching = false);
  }

  Future<void> _apply() async {
    final chosen = [for (final t in widget.tracks) if (_ticked.contains(t.id) && _hits[t.id] != null) _hits[t.id]!];
    if (chosen.isEmpty) return;
    _stop = true;
    setState(() => _applying = true);
    final db = ref.read(dbProvider);
    final handler = ref.read(audioHandlerProvider);
    var ok = 0, failed = 0;
    for (final n in chosen) {
      try {
        // Don't rewrite the file under the player's feet.
        if (handler.currentTrack?.id == n.track.id && handler.player.playing) await handler.pause();
        final updated = await NativeNames.apply(db, n);
        if (updated == null) {
          failed++;
          continue;
        }
        handler.updateTrackInfo(updated);
        ok++;
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() => _applying = false);
    toast(context, failed == 0 ? '已改成原文 $ok 首' : '已改 $ok 首，$failed 首沒有改');
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final found = _hits.values.whereType<NativeName>().length;
    return Scaffold(
      appBar: AppBar(
        title: Text(_searching
            ? '${_stop ? '停止中' : _paused ? '已暫停' : '找原文歌名中'} $_done / ${widget.tracks.length}'
            : '找到 $found 首的原文歌名'),
        actions: [
          FilledButton(
            onPressed: _applying || _ticked.isEmpty ? null : _apply,
            child: Text(_applying ? '更改中…' : '更改 ${_ticked.length} 首'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: ListView(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text('原名來自歌名括號裡的原文，或 iTunes 日本、台灣；只有歌手相同、長度相差 2 秒內的才算。'
              'MP3、M4A、FLAC 會寫進檔案，其他格式只在 OuOPlayer 裡更改。找不到的維持原樣（韓文歌在 iTunes 上是英文名，只能用括號裡的韓文）。',
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

  Widget _row(Track t, NativeName? hit) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return CheckboxListTile(
      value: _ticked.contains(t.id),
      onChanged: hit == null ? null : (v) => setState(() => v == true ? _ticked.add(t.id) : _ticked.remove(t.id)),
      title: Text(hit == null ? t.title : hit.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        hit == null
            ? '${t.artist} • 找不到對得上的原名'
            : '${hit.artist}${hit.album == t.album ? '' : ' • ${hit.album}'}\n原本：${t.title} • ${t.artist}',
        maxLines: 3,
        style: TextStyle(color: muted),
      ),
    );
  }
}
