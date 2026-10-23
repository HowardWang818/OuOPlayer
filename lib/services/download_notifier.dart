import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'download_service.dart';

/// Mirrors download progress into the Android notification (which also keeps
/// the app alive while downloading) and reports a summary when all finish.
/// Windows shows nothing here: downloads run while the window is open.
class DownloadNotifier {
  DownloadNotifier(DownloadService service) {
    if (!Platform.isAndroid) return;
    _sub = service.changes.listen(_onChange);
  }

  static const _channel = MethodChannel('ouo/downloads');
  static const _minInterval = Duration(seconds: 1);

  StreamSubscription? _sub;
  final Map<String, DownloadTask> _batch = {};
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastCount = -1;
  Timer? _trailing;
  List<DownloadTask>? _pending;

  void dispose() {
    _sub?.cancel();
    _trailing?.cancel();
  }

  void _onChange(List<DownloadTask> tasks) {
    final active = tasks.where((t) => t.active).toList();
    for (final t in active) {
      _batch[t.id] = t;
    }
    if (active.isEmpty) {
      _trailing?.cancel();
      if (_batch.isNotEmpty) _finish();
      return;
    }
    // At most one update per second, but always right away when the number
    // of downloads changes; a trailing update shows the latest state.
    final now = DateTime.now();
    if (active.length == _lastCount && now.difference(_lastSent) < _minInterval) {
      _pending = active;
      _trailing ??= Timer(_minInterval, () {
        _trailing = null;
        final p = _pending;
        _pending = null;
        if (p != null) _send(p);
      });
      return;
    }
    _send(active);
  }

  void _send(List<DownloadTask> active) {
    _lastSent = DateTime.now();
    _lastCount = active.length;
    final single = active.length == 1 ? active.first : null;
    final progress = active.fold<double>(0, (s, t) => s + t.progress) / active.length;
    final title = single != null ? single.title : 'OuOPlayer 正在下載 ${active.length} 個項目';
    final text = single != null
        ? (single.detail ?? '準備中…')
        : '${active.where((t) => t.status == DownloadStatus.running).map((t) => t.title).take(2).join('、')}  ·  ${(progress * 100).toStringAsFixed(0)}%';
    _channel.invokeMethod('update', {'title': title, 'text': text, 'progress': (progress * 100).round()}).catchError((_) => null);
  }

  void _finish() {
    var downloaded = 0, skipped = 0, failed = 0;
    for (final t in _batch.values) {
      final songs = t.isGroup ? t.children : [t];
      for (final s in songs) {
        if (s.status == DownloadStatus.failed) failed++;
        if (s.status != DownloadStatus.done) continue;
        if (s.skipped) {
          skipped++;
        } else {
          downloaded += s.files.length;
        }
      }
    }
    _batch.clear();
    _lastCount = -1;
    final parts = [
      if (downloaded > 0) '下載 $downloaded 首',
      if (skipped > 0) '略過 $skipped 首（已存在）',
      if (failed > 0) '$failed 首失敗',
    ];
    // Everything cancelled: just remove the notification.
    _channel.invokeMethod('stop', {'doneText': parts.isEmpty ? null : parts.join(' · ')}).catchError((_) => null);
  }
}
