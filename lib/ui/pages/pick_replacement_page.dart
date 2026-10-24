import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/missing_songs.dart';
import '../widgets/art_image.dart';
import '../widgets/dialogs.dart';

/// 從音樂庫選擇這首歌: when the matcher didn't dare, the user points at the
/// library song a missing entry is; it goes back to its place everywhere.
class PickReplacementPage extends ConsumerStatefulWidget {
  const PickReplacementPage({super.key, required this.missing});
  final Track missing;

  @override
  ConsumerState<PickReplacementPage> createState() => _PickReplacementPageState();
}

class _PickReplacementPageState extends ConsumerState<PickReplacementPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(tracksProvider).value ?? const <Track>[];
    final q = _query.trim().toLowerCase();
    // Most likely first; the search narrows it down.
    final ranked = MissingSongs.rank(widget.missing, all);
    final shown = q.isEmpty ? ranked : ranked.where((t) => [t.title, t.artist, t.album].any((s) => s.toLowerCase().contains(q))).toList();
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: const Text('選擇這首歌')),
      body: Column(children: [
        ListTile(
          leading: const Icon(Icons.music_off_outlined),
          title: Text(widget.missing.title),
          subtitle: Text('缺少 • ${widget.missing.artist}'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: '搜尋音樂庫', isDense: true),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? Center(child: Text('音樂庫裡找不到', style: TextStyle(color: muted)))
              : ListView.builder(
                  itemCount: shown.length,
                  itemBuilder: (_, i) => ListTile(
                    leading: ArtImage(shown[i].art, size: 44),
                    title: Text(shown[i].title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(shown[i].artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: muted)),
                    onTap: () async {
                      final names = await MissingSongs.replace(ref.read(dbProvider), widget.missing.id, shown[i]);
                      if (!context.mounted) return;
                      toast(context, names.isEmpty ? '已補上' : '已補上「${names.join('」「')}」裡的這首歌');
                      Navigator.pop(context);
                    },
                  ),
                ),
        ),
      ]),
    );
  }
}
