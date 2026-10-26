import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';

/// The 「開始？」 dialog of 找歌詞 / 找封面 / 找原文歌名: songs looked up before
/// without a result ([kind] in the lookup_misses table) are skipped unless
/// the user ticks 「也重找之前沒找到的」. Returns the songs to look up, or null.
Future<List<Track>?> confirmLookup(
  BuildContext context,
  WidgetRef ref, {
  required String kind,
  required List<Track> tracks,
  required String Function(int count) title,
  required String Function(int count) message,
}) async {
  final misses = await ref.read(dbProvider).lookupMisses(kind);
  if (!context.mounted) return null;
  final missed = tracks.where((t) => misses.contains(t.id)).length;
  var again = missed == tracks.length;
  return showDialog<List<Track>>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final list = again ? tracks : [for (final t in tracks) if (!misses.contains(t.id)) t];
        return AlertDialog(
          title: Text(title(list.length)),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(message(list.length)),
            if (missed > 0 && missed < tracks.length)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: again,
                onChanged: (v) => setState(() => again = v ?? false),
                title: Text('也重找之前沒找到的（$missed 首）'),
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(onPressed: list.isEmpty ? null : () => Navigator.pop(ctx, list), child: const Text('開始')),
          ],
        );
      },
    ),
  );
}

/// Pause / resume and stop for a running lookup page.
class LookupControls extends StatelessWidget {
  const LookupControls({super.key, required this.paused, required this.stopping, required this.onPause, required this.onStop});
  final bool paused;
  final bool stopping;
  final VoidCallback onPause;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, children: [
        OutlinedButton.icon(
          onPressed: stopping ? null : onPause,
          icon: Icon(paused ? Icons.play_arrow : Icons.pause),
          label: Text(paused ? '繼續' : '暫停'),
        ),
        OutlinedButton.icon(
          onPressed: stopping ? null : onStop,
          icon: const Icon(Icons.stop),
          label: const Text('停止'),
        ),
      ]);
}
