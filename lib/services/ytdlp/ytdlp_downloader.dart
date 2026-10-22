import 'dart:io';

import 'ytdlp_android.dart';
import 'ytdlp_windows.dart';

/// One event from a running yt-dlp job. Both backends feed raw output lines
/// through [YtDlpLineParser] so progress parsing lives in one place.
sealed class YtDlpEvent {}

class YtDlpProgress extends YtDlpEvent {
  final double percent; // 0..100
  final String? eta;
  final int? item;
  final int? itemCount;
  YtDlpProgress(this.percent, this.eta, {this.item, this.itemCount});
}

class YtDlpFileDone extends YtDlpEvent {
  final String path;
  YtDlpFileDone(this.path);
}

class YtDlpLog extends YtDlpEvent {
  final String line;
  YtDlpLog(this.line);
}

class YtDlpFinished extends YtDlpEvent {
  final bool success;
  final String? error;
  YtDlpFinished(this.success, [this.error]);
}

class YtDlpOptions {
  final String url;
  final String format; // mp3 | m4a | opus | best
  final bool playlist;
  final String outDir;
  const YtDlpOptions({required this.url, required this.format, required this.playlist, required this.outDir});

  /// Arguments shared by both backends (url excluded).
  List<String> get args => [
        '-x',
        if (format != 'best') ...['--audio-format', format],
        '--audio-quality', '0',
        '--embed-thumbnail',
        '--embed-metadata',
        '--convert-thumbnails', 'jpg',
        playlist ? '--yes-playlist' : '--no-playlist',
        '--newline',
        '--no-mtime',
        '--no-simulate',
        '--progress',
        '--progress-template', 'download:OUOPROG %(progress._percent_str)s|%(progress._eta_str)s',
        '--print', 'after_move:OUOFILE %(filepath)s',
        '-o', '$outDir${Platform.pathSeparator}%(title).150B.%(ext)s',
      ];
}

class YtDlpLineParser {
  int? _item;
  int? _count;
  static final _itemRe = RegExp(r'Downloading item (\d+) of (\d+)');

  YtDlpEvent? parse(String raw) {
    final line = raw.trim();
    if (line.isEmpty) return null;
    final m = _itemRe.firstMatch(line);
    if (m != null) {
      _item = int.parse(m.group(1)!);
      _count = int.parse(m.group(2)!);
    }
    if (line.startsWith('OUOPROG ')) {
      final parts = line.substring(8).split('|');
      final pct = double.tryParse(parts[0].replaceAll('%', '').trim()) ?? 0;
      return YtDlpProgress(pct, parts.length > 1 ? parts[1].trim() : null, item: _item, itemCount: _count);
    }
    if (line.startsWith('OUOFILE ')) return YtDlpFileDone(line.substring(8).trim());
    return YtDlpLog(line);
  }
}

abstract class YtDlpBackend {
  static YtDlpBackend? create() {
    if (Platform.isWindows) return YtDlpWindows();
    if (Platform.isAndroid) return YtDlpAndroid();
    return null;
  }

  /// Whether yt-dlp (and ffmpeg) are available.
  Future<bool> isReady();

  /// Install the tools if needed. [onStatus] receives human-readable progress.
  Future<void> prepare(void Function(String status) onStatus);

  Future<String?> version();

  /// Update yt-dlp to the newest release. Returns a status message.
  Future<String> update();

  Stream<YtDlpEvent> download(String jobId, YtDlpOptions options);

  Future<void> cancel(String jobId);
}
