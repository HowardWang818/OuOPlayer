import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/models/track.dart';
import 'library_scanner.dart';
import 'ytdlp/ytdlp_downloader.dart';

enum DownloadKind { direct, ytdlp }

enum DownloadStatus { queued, running, done, failed, cancelled }

class DownloadTask {
  final String id;
  final String url;
  final DownloadKind kind;
  final String format;
  final bool playlist;
  String title;
  DownloadStatus status = DownloadStatus.queued;
  double progress = 0; // 0..1
  String? detail;
  String? error;
  final List<String> files = [];
  CancelToken? cancelToken;

  DownloadTask({
    required this.id,
    required this.url,
    required this.kind,
    this.format = 'mp3',
    this.playlist = false,
    String? title,
  }) : title = title ?? url;

  bool get active => status == DownloadStatus.queued || status == DownloadStatus.running;
}

/// Download queue for direct files, podcast episodes and yt-dlp jobs.
class DownloadService {
  DownloadService(this._scanner) : ytdlp = YtDlpBackend.create();

  final LibraryScanner _scanner;
  final YtDlpBackend? ytdlp;
  final _dio = Dio();
  final List<DownloadTask> tasks = [];
  final _changes = StreamController<List<DownloadTask>>.broadcast();
  Stream<List<DownloadTask>> get changes => _changes.stream;

  String outDir = '';
  int maxParallel = 2;
  int _seq = 0;

  void _emit() => _changes.add(List.unmodifiable(tasks));

  DownloadTask add(String url, {DownloadKind? kind, String format = 'mp3', bool playlist = false, String? title}) {
    final k = kind ?? (_looksLikeAudioFile(url) || ytdlp == null ? DownloadKind.direct : DownloadKind.ytdlp);
    final task = DownloadTask(
      id: '${DateTime.now().millisecondsSinceEpoch}_${_seq++}',
      url: url,
      kind: k,
      format: format,
      playlist: playlist,
      title: title,
    );
    tasks.insert(0, task);
    _emit();
    _pump();
    return task;
  }

  void retry(DownloadTask t) {
    t
      ..status = DownloadStatus.queued
      ..progress = 0
      ..error = null
      ..detail = null;
    _emit();
    _pump();
  }

  Future<void> cancel(DownloadTask t) async {
    if (!t.active) return;
    if (t.status == DownloadStatus.queued) {
      t.status = DownloadStatus.cancelled;
      _emit();
      return;
    }
    t.status = DownloadStatus.cancelled;
    t.cancelToken?.cancel();
    if (t.kind == DownloadKind.ytdlp) await ytdlp?.cancel(t.id);
    _emit();
  }

  void remove(DownloadTask t) {
    if (t.active) return;
    tasks.remove(t);
    _emit();
  }

  void clearFinished() {
    tasks.removeWhere((t) => !t.active);
    _emit();
  }

  static bool _looksLikeAudioFile(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    return audioExtensions.any(path.endsWith);
  }

  void _pump() {
    final running = tasks.where((t) => t.status == DownloadStatus.running).length;
    if (running >= maxParallel) return;
    final next = tasks.reversed.where((t) => t.status == DownloadStatus.queued).firstOrNull;
    if (next == null) return;
    next.status = DownloadStatus.running;
    _emit();
    _run(next).whenComplete(() {
      _emit();
      _pump();
    });
    _pump();
  }

  Future<void> _run(DownloadTask t) async {
    // Android only lets apps create audio files in Music/, so partial files,
    // videos and thumbnails go to a private work dir; finished audio is moved over.
    final work = Directory(p.join((await getTemporaryDirectory()).path, 'downloads', t.id));
    try {
      await Directory(outDir).create(recursive: true);
      await work.create(recursive: true);
      if (t.kind == DownloadKind.direct) {
        await _runDirect(t, work.path);
      } else {
        await _runYtDlp(t, work.path);
      }
    } catch (e) {
      if (t.status != DownloadStatus.cancelled) {
        t.status = DownloadStatus.failed;
        t.error = e is DioException ? (e.message ?? e.type.name) : e.toString();
      }
    } finally {
      try {
        await work.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Moves a finished file into [outDir], adds it to the library and returns its new path.
  Future<String> _finish(DownloadTask t, String path) async {
    var target = p.join(outDir, p.basename(path));
    for (var i = 1; File(target).existsSync(); i++) {
      target = p.join(outDir, '${p.basenameWithoutExtension(path)} ($i)${p.extension(path)}');
    }
    try {
      await File(path).rename(target);
    } on FileSystemException {
      // Different filesystem (app cache → shared storage): copy instead.
      await File(path).copy(target);
      await File(path).delete();
    }
    t.files.add(target);
    await _scanner.importFile(target, source: TrackSource.download);
    return target;
  }

  Future<void> _runDirect(DownloadTask t, String workDir) async {
    var name = Uri.decodeComponent(Uri.parse(t.url).pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? 'download');
    name = name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    if (t.title != t.url) {
      final ext = p.extension(name).isEmpty ? '.mp3' : p.extension(name);
      name = '${t.title.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')}$ext';
    } else {
      t.title = name;
    }
    final part = p.join(workDir, name);
    t.cancelToken = CancelToken();
    final res = await _dio.download(t.url, part, cancelToken: t.cancelToken, onReceiveProgress: (r, total) {
      if (total > 0) {
        t.progress = r / total;
        t.detail = '${(r / 1048576).toStringAsFixed(1)} / ${(total / 1048576).toStringAsFixed(1)} MB';
        _emit();
      }
    });
    // A URL ending in ".mp3"/".ogg" can still be a web page (e.g. a wiki file page).
    final type = res.headers.value(Headers.contentTypeHeader) ?? '';
    if (type.startsWith('text/')) {
      await File(part).delete();
      if (ytdlp == null) throw '這個網址是網頁，不是音訊檔';
      t
        ..progress = 0
        ..detail = '改用 yt-dlp…';
      _emit();
      return _runYtDlp(t, workDir);
    }
    await _finish(t, part);
    t
      ..status = DownloadStatus.done
      ..progress = 1;
  }

  Future<void> _runYtDlp(DownloadTask t, String workDir) async {
    final backend = ytdlp;
    if (backend == null) throw '此平台不支援 yt-dlp';
    if (!await backend.isReady()) {
      await backend.prepare((s) {
        t.detail = s;
        _emit();
      });
    }
    final opts = YtDlpOptions(url: t.url, format: t.format, playlist: t.playlist, outDir: workDir);
    String? lastLog;
    await for (final e in backend.download(t.id, opts)) {
      switch (e) {
        case YtDlpProgress():
          t.progress = e.percent / 100;
          t.detail = [
            if (e.itemCount != null) '第 ${e.item}/${e.itemCount} 首',
            '${e.percent.toStringAsFixed(1)}%',
            if (e.eta != null && e.eta != 'NA' && e.eta != 'Unknown') '剩餘 ${e.eta}',
          ].join('  ·  ');
          _emit();
        case YtDlpFileDone():
          if (File(e.path).existsSync()) {
            if (t.title == t.url) t.title = p.basenameWithoutExtension(e.path);
            await _finish(t, e.path);
            _emit();
          }
        case YtDlpLog():
          lastLog = e.line;
          if (e.line.startsWith('[ExtractAudio]') || e.line.startsWith('[EmbedThumbnail]')) {
            t.detail = '轉檔中…';
            _emit();
          }
        case YtDlpFinished():
          if (t.status == DownloadStatus.cancelled) return;
          if (e.success || t.files.isNotEmpty) {
            t
              ..status = DownloadStatus.done
              ..progress = 1
              ..detail = '${t.files.length} 個檔案';
          } else {
            t
              ..status = DownloadStatus.failed
              ..error = e.error ?? lastLog ?? '下載失敗';
          }
      }
    }
  }
}
