import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../data/models/track.dart';
import '../../services/artists.dart';
import '../pages/collection_page.dart';
import '../pages/folder_browser_page.dart';
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

/// 在資料夾中顯示. Windows: File Explorer with the file selected. Android:
/// phones' file managers can't be told to select a file, so OuOPlayer's own
/// 瀏覽資料夾 opens at the song's folder.
Future<void> showInFolder(BuildContext context, Track t) async {
  if (!File(t.uri).existsSync()) {
    toast(context, '找不到這首歌的檔案');
    return;
  }
  if (Platform.isWindows) {
    await Process.run('explorer.exe', ['/select,', t.uri]);
    return;
  }
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => FolderBrowserPage(folder: p.dirname(t.uri))));
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
