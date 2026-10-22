import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../../services/download_service.dart';
import '../../theme/app_theme.dart';
import '../widgets/dialogs.dart';

/// youtube-dl-gui style downloader: paste URL → pick format → queue with progress.
class DownloadsPage extends ConsumerStatefulWidget {
  const DownloadsPage({super.key});

  @override
  ConsumerState<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends ConsumerState<DownloadsPage> {
  final _ctrl = TextEditingController();
  bool _playlist = false;
  bool _direct = false;
  String? _toolStatus;
  String? _version;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refreshVersion();
  }

  Future<void> _refreshVersion() async {
    final yt = ref.read(downloadServiceProvider).ytdlp;
    if (yt == null) return;
    try {
      final ready = await yt.isReady();
      final v = ready ? await yt.version() : null;
      if (mounted) setState(() => _version = ready ? (v ?? '已安裝') : null);
    } catch (_) {}
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) _ctrl.text = data!.text!.trim();
  }

  void _start() {
    final urls = _ctrl.text.split(RegExp(r'\s+')).where((u) => u.startsWith('http')).toList();
    if (urls.isEmpty) {
      toast(context, '請輸入有效的網址');
      return;
    }
    final svc = ref.read(downloadServiceProvider);
    final fmt = ref.read(settingsProvider).ytFormat;
    for (final u in urls) {
      svc.add(u, kind: _direct ? DownloadKind.direct : null, format: fmt, playlist: _playlist);
    }
    _ctrl.clear();
  }

  Future<void> _installOrUpdate() async {
    final yt = ref.read(downloadServiceProvider).ytdlp;
    if (yt == null) return;
    setState(() => _busy = true);
    try {
      if (!await yt.isReady()) {
        await yt.prepare((s) => mounted ? setState(() => _toolStatus = s) : null);
      } else {
        setState(() => _toolStatus = '正在更新 yt-dlp…');
        final msg = await yt.update();
        setState(() => _toolStatus = msg);
      }
    } catch (e) {
      setState(() => _toolStatus = '失敗：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
      _refreshVersion();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(downloadsProvider).value ?? const [];
    final settings = ref.watch(settingsProvider);
    final svc = ref.read(downloadServiceProvider);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final hasYt = svc.ytdlp != null;

    return Scaffold(
      appBar: AppBar(title: const Text('下載'), actions: [
        if (tasks.any((t) => !t.active)) TextButton(onPressed: svc.clearFinished, child: const Text('清除已完成')),
      ]),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _ctrl,
            minLines: 1,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: '貼上影片 / 音樂 / 播放清單網址（可一次貼多個）',
              prefixIcon: const Icon(Icons.link),
              suffixIcon: IconButton(icon: const Icon(Icons.content_paste), tooltip: '貼上', onPressed: _paste),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (hasYt && !_direct)
              DropdownButton<String>(
                value: settings.ytFormat,
                underline: const SizedBox(),
                items: const [
                  DropdownMenuItem(value: 'mp3', child: Text('MP3')),
                  DropdownMenuItem(value: 'm4a', child: Text('M4A (AAC)')),
                  DropdownMenuItem(value: 'opus', child: Text('Opus')),
                  DropdownMenuItem(value: 'flac', child: Text('FLAC')),
                  DropdownMenuItem(value: 'best', child: Text('原始最佳音質')),
                ],
                onChanged: (v) => ref.read(settingsProvider.notifier).setYtFormat(v!),
              ),
            if (hasYt && !_direct)
              FilterChip(
                label: const Text('下載整個播放清單'),
                selected: _playlist,
                onSelected: (v) => setState(() => _playlist = v),
              ),
            FilterChip(
              label: const Text('直接下載檔案'),
              selected: _direct || !hasYt,
              onSelected: hasYt ? (v) => setState(() => _direct = v) : null,
            ),
            FilledButton.icon(onPressed: _start, icon: const Icon(Icons.download), label: const Text('下載')),
          ]),
        ),
        if (hasYt)
          Card(
            margin: const EdgeInsets.all(16),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Icon(_version == null ? Icons.build_circle_outlined : Icons.check_circle, color: _version == null ? muted : AppColors.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_version == null ? 'yt-dlp 尚未安裝' : 'yt-dlp $_version', style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text(_toolStatus ?? '下載位置：${settings.downloadDir}', style: TextStyle(fontSize: 12, color: muted)),
                  ]),
                ),
                _busy
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                    : TextButton(onPressed: _installOrUpdate, child: Text(_version == null ? '安裝' : '更新')),
              ]),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('請只下載你有權利保存的內容，並遵守來源網站的服務條款與著作權法。',
              style: TextStyle(fontSize: 12, color: muted)),
        ),
        const SizedBox(height: 8),
        if (tasks.isEmpty)
          Padding(
            padding: const EdgeInsets.all(48),
            child: Center(child: Text('沒有下載項目', style: TextStyle(color: muted))),
          ),
        for (final t in tasks) _TaskTile(task: t),
      ]),
    );
  }
}

class _TaskTile extends ConsumerWidget {
  const _TaskTile({required this.task});
  final DownloadTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final svc = ref.read(downloadServiceProvider);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final (icon, color) = switch (task.status) {
      DownloadStatus.queued => (Icons.schedule, muted),
      DownloadStatus.running => (Icons.downloading, AppColors.accent),
      DownloadStatus.done => (Icons.check_circle, AppColors.accent),
      DownloadStatus.failed => (Icons.error_outline, Colors.redAccent),
      DownloadStatus.cancelled => (Icons.cancel_outlined, muted),
    };
    final statusText = switch (task.status) {
      DownloadStatus.queued => '等待中',
      DownloadStatus.running => task.detail ?? '準備中…',
      DownloadStatus.done => '完成${task.detail != null ? ' · ${task.detail}' : ''}',
      DownloadStatus.failed => task.error ?? '失敗',
      DownloadStatus.cancelled => '已取消',
    };
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(statusText, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: muted)),
        if (task.status == DownloadStatus.running)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: LinearProgressIndicator(value: task.progress > 0 ? task.progress : null, minHeight: 3),
          ),
      ]),
      trailing: switch (task.status) {
        DownloadStatus.queued || DownloadStatus.running =>
          IconButton(icon: const Icon(Icons.close), tooltip: '取消', onPressed: () => svc.cancel(task)),
        DownloadStatus.failed || DownloadStatus.cancelled => Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(icon: const Icon(Icons.refresh), tooltip: '重試', onPressed: () => svc.retry(task)),
            IconButton(icon: const Icon(Icons.delete_outline), tooltip: '移除', onPressed: () => svc.remove(task)),
          ]),
        DownloadStatus.done => IconButton(icon: const Icon(Icons.delete_outline), tooltip: '從清單移除', onPressed: () => svc.remove(task)),
      },
    );
  }
}
