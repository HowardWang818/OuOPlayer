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

/// Title of the playlist being downloaded (emitted before each file).
class YtDlpPlaylistTitle extends YtDlpEvent {
  final String title;
  YtDlpPlaylistTitle(this.title);
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
        // Song number / total ride along with the progress: with --print yt-dlp
        // is quiet and never prints its own "Downloading item N of M" line.
        '--progress-template',
        'download:OUOPROG %(progress._percent_str)s|%(progress._eta_str)s|%(info.playlist_autonumber)s|%(info.n_entries)s',
        // Fetch several pieces of a song at once (DASH/HLS sources).
        '--concurrent-fragments', '4',
        // Printed in this order after each file, so the title arrives first.
        '--print', 'after_move:OUOPLAYLIST %(playlist_title)s',
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
      // "NA" for single videos; keep the "Downloading item" fallback then.
      final item = parts.length > 2 ? int.tryParse(parts[2].trim()) : null;
      final count = parts.length > 3 ? int.tryParse(parts[3].trim()) : null;
      return YtDlpProgress(pct, parts.length > 1 ? parts[1].trim() : null, item: item ?? _item, itemCount: count ?? _count);
    }
    if (line.startsWith('OUOFILE ')) return YtDlpFileDone(line.substring(8).trim());
    if (line.startsWith('OUOPLAYLIST')) {
      final title = line.substring(11).trim();
      // "NA" when the URL is a single video rather than a playlist.
      return title.isEmpty || title == 'NA' ? null : YtDlpPlaylistTitle(title);
    }
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

  Stream<YtDlpEvent> download(String jobId, YtDlpOptions options) => run(jobId, options.url, options.args);

  /// Runs yt-dlp with arbitrary [args] (e.g. listing a playlist without downloading).
  Stream<YtDlpEvent> run(String jobId, String url, List<String> args);

  Future<void> cancel(String jobId);
}
