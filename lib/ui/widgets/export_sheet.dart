import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models/track.dart';
import '../../services/playlist_export.dart';
import 'dialogs.dart';

/// 複製／匯出歌單: copy as text, or save as .txt / .csv / .m3u8 where the
/// user picks (system save dialog on Android and Windows).
Future<void> showExportSheet(BuildContext context, String name, List<Track> tracks) async {
  if (tracks.isEmpty) {
    toast(context, '沒有歌曲可以匯出');
    return;
  }
  // Songs that aren't on the device have nothing to export.
  final export = PlaylistExport(name, [for (final t in tracks) if (t.source != TrackSource.missing) t]);
  await showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis), subtitle: Text('${tracks.length} 首歌曲')),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.copy),
            title: const Text('複製為文字'),
            subtitle: const Text('「1. 歌名 - 歌手」，可以貼到聊天或記事本'),
            onTap: () async {
              Navigator.pop(ctx);
              await Clipboard.setData(ClipboardData(text: export.text()));
              if (context.mounted) toast(context, '已複製 ${tracks.length} 首');
            },
          ),
          for (final f in ExportFormat.values)
            ListTile(
              leading: Icon(switch (f) {
                ExportFormat.text => Icons.description_outlined,
                ExportFormat.csv => Icons.table_chart_outlined,
                ExportFormat.m3u8 => Icons.queue_music,
              }),
              title: Text('匯出 .${f.extension}'),
              subtitle: Text(f.label),
              onTap: () async {
                Navigator.pop(ctx);
                await _save(context, export, f);
              },
            ),
        ]),
      ),
    ),
  );
}

Future<void> _save(BuildContext context, PlaylistExport export, ExportFormat f) async {
  try {
    final saved = await FilePicker.saveFile(
      dialogTitle: '匯出歌單',
      fileName: export.fileName(f),
      bytes: export.bytes(f),
      mimeType: f.mimeType,
      type: FileType.custom,
      allowedExtensions: [f.extension],
    );
    if (context.mounted && saved != null) toast(context, '已匯出 ${export.fileName(f)}');
  } catch (e) {
    if (context.mounted) toast(context, '匯出失敗：$e');
  }
}
