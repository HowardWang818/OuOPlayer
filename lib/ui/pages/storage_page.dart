import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../../services/artist_images.dart';
import '../../services/storage_usage.dart';
import '../widgets/dialogs.dart';
import 'settings/section_page.dart';

/// 儲存空間: how much space OuOPlayer's own caches use, and clearing them
/// (after a warning). Music files are never touched here.
class StoragePage extends ConsumerStatefulWidget {
  const StoragePage({super.key});

  @override
  ConsumerState<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends ConsumerState<StoragePage> {
  final _sizes = <CacheKind, int>{};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    for (final k in CacheKind.values) {
      // The cover cache holds the artist photos' folder: counted apart.
      final size = await folderSize(await cacheDir(k), recursive: k != CacheKind.art);
      if (mounted) setState(() => _sizes[k] = size);
    }
  }

  Future<void> _clear(CacheKind k) async {
    if (k == CacheKind.downloads && ref.read(downloadServiceProvider).tasks.any((t) => t.active)) {
      toast(context, '還有下載在進行中，完成或取消後才能清除');
      return;
    }
    final what = k == CacheKind.art ? '未使用的封面快取' : k.label;
    if (!await confirmDelete(context, title: '清除$what？', message: '${k.description}\n音樂檔案不會被動到。', action: '清除')) return;
    setState(() => _busy = true);
    try {
      final before = _sizes[k] ?? 0;
      if (k == CacheKind.art) {
        await ref.read(scannerProvider).cleanArtCache();
      } else if (k == CacheKind.artists) {
        await ArtistImages.clear();
        ref.invalidate(artistImageProvider);
      } else {
        await clearFolder(await cacheDir(k));
      }
      if (k == CacheKind.lyrics) ref.invalidate(lyricsProvider);
      final after = await folderSize(await cacheDir(k), recursive: k != CacheKind.art);
      if (!mounted) return;
      setState(() => _sizes[k] = after);
      toast(context, '已清除 ${formatBytes((before - after).clamp(0, before))}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _sizes.values.fold<int>(0, (a, b) => a + b);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return SettingsSectionPage(title: '儲存空間', children: [
        ListTile(
          title: const Text('OuOPlayer 的快取'),
          subtitle: Text(_sizes.length < CacheKind.values.length ? '計算中…' : '共 ${formatBytes(total)}（不含音樂檔案）'),
        ),
        const Divider(),
        for (final k in CacheKind.values)
          ListTile(
            leading: Icon(switch (k) {
              CacheKind.art => Icons.image_outlined,
              CacheKind.artists => Icons.person_outline,
              CacheKind.lyrics => Icons.lyrics_outlined,
              CacheKind.downloads => Icons.downloading,
            }),
            title: Text(k.label),
            subtitle: Text('${_sizes[k] == null ? '計算中…' : formatBytes(_sizes[k]!)}\n${k.description}', style: TextStyle(color: muted)),
            isThreeLine: true,
            trailing: Platform.isWindows
                ? SettingButton('清除', onPressed: _busy || (_sizes[k] ?? 0) == 0 ? null : () => _clear(k))
                : TextButton(onPressed: _busy || (_sizes[k] ?? 0) == 0 ? null : () => _clear(k), child: const Text('清除')),
          ),
      ]);
  }
}
