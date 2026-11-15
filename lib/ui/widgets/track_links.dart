import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models/track.dart';
import '../../services/artists.dart';
import '../pages/collection_page.dart';
import 'dialogs.dart';

/// The artist a song is listed under (the first one credited), as in the library.
String primaryArtist(Track t) => ArtistDirectory(const []).primary(t.artist) ?? t.artist;

void openArtist(BuildContext context, Track t) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => CollectionPage.artist(primaryArtist(t))));

void openAlbum(BuildContext context, Track t) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => CollectionPage.album(t.album)));

/// Whether a song has an artist / album page to go to.
bool hasPages(Track t) => t.source != TrackSource.url && t.source != TrackSource.podcast && t.source != TrackSource.missing;

/// Whether [showInFolder] can show this song (a file on this device).
bool isLocalFile(Track t) => !t.isRemote && t.uri.isNotEmpty && t.source != TrackSource.missing && t.source != TrackSource.podcast;

/// 打開資料夾 (the one way, 1.20.10: songs of the library and downloads).
/// Windows: File Explorer with the file selected. Android: the system Files
/// app at its folder; where that isn't possible, the folder's path to copy.
Future<void> showInFolder(BuildContext context, String path) async {
  if (!File(path).existsSync() && !Directory(path).existsSync()) {
    toast(context, '找不到這個檔案');
    return;
  }
  if (Platform.isWindows) {
    await Process.run('explorer.exe', ['/select,', path]);
    return;
  }
  final dir = Directory(path).existsSync() ? path : File(path).parent.path;
  var opened = false;
  try {
    opened = await const MethodChannel('ouo/folder').invokeMethod<bool>('open', {'path': dir}) ?? false;
  } catch (_) {}
  if (opened || !context.mounted) return;
  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => AlertDialog(
      title: const Text('檔案位置'),
      content: SelectableText(dir),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('關閉')),
        FilledButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: dir));
            Navigator.pop(ctx);
            toast(context, '已複製位置');
          },
          child: const Text('複製'),
        ),
      ],
    ),
  );
}

/// Text that opens [onTap]'s page when clicked (with a pointer cursor on desktop).
class LinkText extends StatelessWidget {
  const LinkText(this.text, {super.key, required this.onTap, this.style, this.maxLines = 1});
  final String text;
  final VoidCallback? onTap;
  final TextStyle? style;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final label = Text(text, maxLines: maxLines, overflow: TextOverflow.ellipsis, style: style);
    if (onTap == null) return label;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: label),
    );
  }
}
