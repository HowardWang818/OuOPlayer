import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../providers/providers.dart';
import '../../services/download_service.dart';
import '../../theme/app_theme.dart';
import '../widgets/dialogs.dart';

(IconData, Color) downloadStatusIcon(DownloadStatus s, Color muted) => switch (s) {
      DownloadStatus.queued => (Icons.schedule, muted),
      DownloadStatus.running => (Icons.downloading, AppColors.accent),
      DownloadStatus.done => (Icons.check_circle, AppColors.accent),
      DownloadStatus.failed => (Icons.error_outline, Colors.redAccent),
      DownloadStatus.cancelled => (Icons.cancel_outlined, muted),
    };

String downloadStatusText(DownloadTask t) => switch (t.status) {
      DownloadStatus.queued => '等待中',
      DownloadStatus.running => t.detail ?? '準備中…',
      DownloadStatus.done => '完成${t.detail != null ? ' · ${t.detail}' : ''}',
      DownloadStatus.failed => '失敗',
      DownloadStatus.cancelled => '已取消',
    };

/// Everything about one download: full error, files, yt-dlp output, actions.
class DownloadDetailPage extends ConsumerWidget {
  const DownloadDetailPage({super.key, required this.taskId});
  final String taskId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(downloadsProvider).value ?? const <DownloadTask>[];
    final task = tasks.where((t) => t.id == taskId).firstOrNull;
    final svc = ref.read(downloadServiceProvider);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    if (task == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('這筆下載已移除')));
    }
    final (icon, color) = downloadStatusIcon(task.status, muted);

    Widget section(String title, {Widget? action}) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 8, 4),
          child: Row(children: [
            Expanded(child: Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold))),
            if (action != null) action,
          ]),
        );

    void copy(String text) {
      Clipboard.setData(ClipboardData(text: text));
      toast(context, '已複製');
    }

    return Scaffold(
      appBar: AppBar(title: const Text('下載詳細資料')),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        ListTile(
          leading: Icon(icon, color: color, size: 32),
          title: Text(task.title, style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text(downloadStatusText(task), style: TextStyle(color: muted)),
        ),
        if (task.status == DownloadStatus.running)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(value: task.progress > 0 ? task.progress : null),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Wrap(spacing: 8, children: [
            if (task.active)
              OutlinedButton.icon(onPressed: () => svc.cancel(task), icon: const Icon(Icons.close), label: const Text('取消')),
            if (!task.active && task.status != DownloadStatus.done)
              FilledButton.icon(onPressed: () => svc.retry(task), icon: const Icon(Icons.refresh), label: const Text('重試')),
            if (!task.active)
              OutlinedButton.icon(
                onPressed: () async {
                  if (!await confirmDelete(context,
                      title: '從下載清單移除？', message: '只會移除這筆紀錄，已下載的檔案不會被刪除。')) {
                    return;
                  }
                  svc.remove(task);
                  if (context.mounted) Navigator.pop(context);
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('從清單移除'),
              ),
          ]),
        ),
        if (task.error != null) ...[
          section('錯誤訊息', action: IconButton(icon: const Icon(Icons.copy), tooltip: '複製', onPressed: () => copy(task.error!))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SelectableText(task.error!, style: const TextStyle(color: Colors.redAccent)),
          ),
        ],
        section('網址', action: IconButton(icon: const Icon(Icons.copy), tooltip: '複製', onPressed: () => copy(task.url))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SelectableText(task.url, style: TextStyle(color: muted)),
        ),
        if (task.playlistName != null && task.playlistId != null) ...[
          section('播放清單'),
          ListTile(leading: const Icon(Icons.queue_music), title: Text(task.playlistName!)),
        ],
        if (task.files.isNotEmpty) ...[
          section('檔案（${task.files.length}）'),
          for (final f in task.files)
            ListTile(
              dense: true,
              leading: const Icon(Icons.music_note),
              title: Text(p.basename(f), maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: () async {
                final track = await ref.read(dbProvider).track(f);
                if (track != null) ref.read(audioHandlerProvider).playTracks([track]);
              },
            ),
        ],
        if (task.log.isNotEmpty) ...[
          section('執行紀錄', action: IconButton(icon: const Icon(Icons.copy), tooltip: '複製全部', onPressed: () => copy(task.log.join('\n')))),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(8)),
            child: SelectableText(task.log.join('\n'), style: const TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.4)),
          ),
        ],
      ]),
    );
  }
}
