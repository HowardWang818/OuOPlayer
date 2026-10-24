import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../../services/artist_images.dart';
import '../../services/artists.dart';
import '../pages/collection_page.dart';
import 'art_image.dart';
import 'dialogs.dart';

/// 歌手頁 ⋮ →「重新命名歌手」: only OuOPlayer's name changes, never the files.
/// Naming it like another artist merges the two (after a warning).
Future<void> renameArtist(BuildContext context, WidgetRef ref, String name) async {
  final to = (await promptText(context, title: '重新命名歌手', initial: name))?.trim();
  if (to == null || to.isEmpty || to == name || !context.mounted) return;
  final dir = ArtistDirectory(const []);
  final artists = await ref.read(artistsProvider.future);
  final other = artists.where((a) => dir.keyOf(a.name) == dir.keyOf(to) && dir.keyOf(a.name) != dir.keyOf(name)).firstOrNull;
  if (other != null && context.mounted) {
    final mine = artists.where((a) => dir.keyOf(a.name) == dir.keyOf(name)).firstOrNull?.count ?? 0;
    if (!await confirmDelete(context,
        title: '和「${other.name}」合併？',
        message: '已經有叫「${other.name}」的歌手（${other.count} 首）。改名後兩位會合併成一位，共 ${other.count + mine} 首。\n'
            '音樂檔不會被修改，之後可以用「還原原本的名字」分開。',
        action: '合併')) {
      return;
    }
  }
  final shown = other?.name ?? to;
  await ref.read(settingsProvider.notifier).setArtistRenames(ArtistRenames.renamed(ArtistRenames.all, name, shown));
  await ArtistImages.moveCustom(name, shown);
  ref.invalidate(artistImageProvider);
  if (!context.mounted) return;
  toast(context, other == null ? '已改名為「$shown」' : '已和「$shown」合併');
  Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => CollectionPage.artist(shown)));
}

/// Back to the name(s) in the song files.
Future<void> restoreArtistName(BuildContext context, WidgetRef ref, String name) async {
  final originals = ArtistRenames.originals(name);
  if (originals.isEmpty) return;
  if (!await confirmDelete(context,
      title: '還原原本的名字？',
      message: '會移除你設定的名字「$name」，改回「${originals.join('」「')}」。',
      action: '還原')) {
    return;
  }
  await ref.read(settingsProvider.notifier).setArtistRenames(ArtistRenames.restored(ArtistRenames.all, name));
  await ArtistImages.moveCustom(name, originals.first);
  ref.invalidate(artistImageProvider);
  if (!context.mounted) return;
  final back = ArtistDirectory(const []).canonical(originals.first);
  toast(context, '已還原為「$back」');
  Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => CollectionPage.artist(back)));
}

/// An image from the phone as the artist's picture.
Future<void> pickArtistPhoto(BuildContext context, WidgetRef ref, String name) async {
  final picked = await FilePicker.pickFiles(type: FileType.image, dialogTitle: '選擇歌手圖片');
  final src = picked.firstOrNull?.path;
  if (src == null) return;
  await ArtistImages.setCustomFile(name, src);
  ref.invalidate(artistImageProvider);
  if (context.mounted) toast(context, '已更換歌手圖片');
}

/// Back to the automatic (Deezer) photo, after a warning.
Future<void> removeArtistPhoto(BuildContext context, WidgetRef ref, String name) async {
  if (!await confirmDelete(context, title: '移除自訂圖片？', message: '會改回自動找到的歌手照片。')) return;
  await ArtistImages.removeCustom(name);
  ref.invalidate(artistImageProvider);
  if (context.mounted) toast(context, '已移除自訂圖片');
}

/// Pick one of Deezer's artists' photos (when the automatic one is wrong).
Future<void> pickDeezerPhoto(BuildContext context, WidgetRef ref, String name) async {
  final images = ref.read(artistImagesProvider);
  final url = await showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.6,
        child: FutureBuilder<List<(String, String)>>(
          future: images.candidates(name),
          builder: (ctx, snap) {
            final muted = Theme.of(ctx).colorScheme.onSurfaceVariant;
            if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
            if (snap.hasError) return Center(child: Text('無法連線到 Deezer', style: TextStyle(color: muted)));
            final list = snap.data ?? const [];
            if (list.isEmpty) return Center(child: Text('Deezer 找不到「$name」', style: TextStyle(color: muted)));
            return Column(children: [
              Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('從 Deezer 挑選「$name」的照片', style: Theme.of(ctx).textTheme.titleMedium)),
              Expanded(
                child: GridView.extent(
                  maxCrossAxisExtent: 130,
                  padding: const EdgeInsets.all(12),
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.78,
                  children: [
                    for (final (n, pic) in list)
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => Navigator.pop(ctx, pic),
                        child: Column(children: [
                          LayoutBuilder(builder: (_, c) => ArtImage(pic, size: c.maxWidth, circle: true, icon: Icons.person)),
                          const SizedBox(height: 6),
                          Text(n, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
                        ]),
                      ),
                  ],
                ),
              ),
            ]);
          },
        ),
      ),
    ),
  );
  if (url == null) return;
  try {
    await images.setCustomUrl(name, url);
    ref.invalidate(artistImageProvider);
    if (context.mounted) toast(context, '已更換歌手圖片');
  } catch (_) {
    if (context.mounted) toast(context, '下載圖片失敗，請稍後再試');
  }
}
