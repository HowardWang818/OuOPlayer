import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../theme/app_theme.dart';
import '../widgets/art_image.dart';
import '../widgets/dialogs.dart';

/// 從本地音樂加入: tick songs from the library (with search) and add them to
/// a playlist in one go. Songs already in it are marked, and can be ticked
/// again only when 允許歌曲重複 is on.
class PickSongsPage extends ConsumerStatefulWidget {
  const PickSongsPage({super.key, required this.playlistId, required this.playlistName});
  final int playlistId;
  final String playlistName;

  @override
  ConsumerState<PickSongsPage> createState() => _PickSongsPageState();
}

class _PickSongsPageState extends ConsumerState<PickSongsPage> {
  final _picked = <String>[];
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(tracksProvider).value ?? const <Track>[];
    final inList = {for (final t in ref.watch(playlistTracksProvider(widget.playlistId)).value ?? const <Track>[]) t.id};
    final allowDup = ref.watch(settingsProvider.select((s) => s.allowPlaylistDuplicates));
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty
        ? all
        : all.where((t) => [t.title, t.artist, t.album].any((s) => s.toLowerCase().contains(q))).toList();
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(
        title: Text(_picked.isEmpty ? '加入「${widget.playlistName}」' : '已選 ${_picked.length} 首'),
        actions: [
          FilledButton(
            onPressed: _picked.isEmpty ? null : () => _add(all),
            child: const Text('加入'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: '搜尋歌名、歌手、專輯', isDense: true),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? Center(child: Text(all.isEmpty ? '音樂庫裡還沒有歌曲' : '找不到符合的歌曲', style: TextStyle(color: muted)))
              : ListView.builder(
                  itemCount: shown.length,
                  itemBuilder: (_, i) {
                    final t = shown[i];
                    final already = inList.contains(t.id);
                    final locked = already && !allowDup;
                    return CheckboxListTile(
                      value: locked || _picked.contains(t.id),
                      onChanged: locked
                          ? null
                          : (v) => setState(() => v == true ? _picked.add(t.id) : _picked.remove(t.id)),
                      secondary: ArtImage(t.art, size: 44),
                      activeColor: AppColors.accent,
                      title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(already ? '${t.artist} • 已在清單中' : t.artist,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: muted)),
                    );
                  },
                ),
        ),
      ]),
    );
  }

  Future<void> _add(List<Track> all) async {
    final byId = {for (final t in all) t.id: t};
    // In the order they were ticked.
    final tracks = [for (final id in _picked) if (byId[id] != null) byId[id]!];
    final allowDup = ref.read(settingsProvider).allowPlaylistDuplicates;
    final added = await ref.read(dbProvider).addToPlaylist(widget.playlistId, tracks, allowDuplicates: allowDup);
    if (!mounted) return;
    toast(context, '已加入 $added 首到「${widget.playlistName}」');
    Navigator.pop(context);
  }
}
