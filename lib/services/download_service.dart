import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/db/database.dart';
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

  /// Library playlist the finished songs go into: chosen by the user
  /// ("下載到這個播放清單") or created from the source playlist's title.
  int? playlistId;
  String? playlistName;

  /// Files that already existed and were kept instead of the new copy.
  int duplicates = 0;

  /// yt-dlp output (last [maxLog] lines), shown on the detail page.
  final List<String> log = [];
  static const maxLog = 300;

  /// A playlist download is split into one child task per song so several
  /// songs download at once; the parent's status and progress come from them.
  final List<DownloadTask> children = [];
  DownloadTask? parent;

  /// For a child: its 1-based position in the source playlist.
  int index = 0;

  /// For a group: library playlist position of song #1, so parallel
  /// downloads still land in the source order.
  int playlistBase = 0;

  bool get isGroup => children.isNotEmpty;

  DownloadTask({
    required this.id,
    required this.url,
    required this.kind,
    this.format = 'mp3',
    this.playlist = false,
    this.playlistId,
    this.playlistName,
    String? title,
  }) : title = title ?? url;

  bool get active => status == DownloadStatus.queued || status == DownloadStatus.running;

  void addLog(String line) {
    log.add(line);
    if (log.length > maxLog) log.removeRange(0, log.length - maxLog);
  }
}

/// Download queue for direct files, podcast episodes and yt-dlp jobs.
class DownloadService {
  DownloadService(this._scanner, this._db) : ytdlp = YtDlpBackend.create();

  final LibraryScanner _scanner;
  final AppDatabase _db;
  final YtDlpBackend? ytdlp;
  final _dio = Dio();
  final List<DownloadTask> tasks = [];
  final _changes = StreamController<List<DownloadTask>>.broadcast();
  Stream<List<DownloadTask>> get changes => _changes.stream;

  String outDir = '';
  int maxParallel = 3;
  int _seq = 0;

  void _emit() {
    for (final t in tasks) {
      if (t.isGroup) _refreshGroup(t);
    }
    _changes.add(List.unmodifiable(tasks));
  }

  /// Every task, including the songs inside split playlists (for lookups).
  Iterable<DownloadTask> get allTasks sync* {
    for (final t in tasks) {
      yield t;
      yield* t.children;
    }
  }

  /// Status, progress and summary of a split playlist, from its songs.
  void _refreshGroup(DownloadTask g) {
    final kids = g.children;
    final done = kids.where((c) => c.status == DownloadStatus.done).length;
    final failed = kids.where((c) => c.status == DownloadStatus.failed).length;
    final cancelled = kids.where((c) => c.status == DownloadStatus.cancelled).length;
    final finished = done + failed + cancelled;
    g.progress = kids.fold<double>(0, (sum, c) => sum + (c.active ? c.progress : 1)) / kids.length;
    g.files
      ..clear()
      ..addAll([for (final c in [...kids]..sort((a, b) => a.index.compareTo(b.index))) ...c.files]);
    g.duplicates = kids.fold(0, (sum, c) => sum + c.duplicates);
    if (finished < kids.length) {
      g.status = DownloadStatus.running;
      g.error = null;
      g.detail = '已完成 $done/${kids.length} 首  ·  ${(g.progress * 100).toStringAsFixed(1)}%';
      return;
    }
    g.status = done > 0 ? DownloadStatus.done : (failed > 0 ? DownloadStatus.failed : DownloadStatus.cancelled);
    g.error = failed > 0 ? '$failed 首下載失敗，點進去查看每首的原因' : null;
    g.detail = [
      _doneDetail(g),
      if (failed > 0) '$failed 首失敗',
      if (cancelled > 0) '$cancelled 首已取消',
    ].join(' · ');
  }

  DownloadTask add(
    String url, {
    DownloadKind? kind,
    String format = 'mp3',
    bool playlist = false,
    String? title,
    int? playlistId,
    String? playlistName,
  }) {
    final k = kind ?? (_looksLikeAudioFile(url) || ytdlp == null ? DownloadKind.direct : DownloadKind.ytdlp);
    final task = DownloadTask(
      id: '${DateTime.now().millisecondsSinceEpoch}_${_seq++}',
      url: url,
      kind: k,
      format: format,
      playlist: playlist,
      title: title,
      playlistId: playlistId,
      playlistName: playlistName,
    );
    tasks.insert(0, task);
    _emit();
    _pump();
    return task;
  }

  void retry(DownloadTask t) {
    if (t.isGroup) {
      for (final c in t.children) {
        if (c.status == DownloadStatus.failed || c.status == DownloadStatus.cancelled) retry(c);
      }
      return;
    }
    t
      ..status = DownloadStatus.queued
      ..progress = 0
      ..error = null
      ..detail = null;
    t.addLog('— 重試 —');
    _emit();
    _pump();
  }

  Future<void> cancel(DownloadTask t) async {
    if (!t.active) return;
    if (t.isGroup) {
      for (final c in t.children) {
        await cancel(c);
      }
      return;
    }
    if (t.status == DownloadStatus.queued) {
      t.status = DownloadStatus.cancelled;
      _emit();
      return;
    }
    t.status = DownloadStatus.cancelled;
    t.cancelToken?.cancel();
    if (t.kind == DownloadKind.ytdlp) {
      await ytdlp?.cancel(t.id);
      await ytdlp?.cancel('${t.id}_list'); // still listing a playlist
    }
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
    // Oldest first; a split playlist contributes its songs in order.
    final work = [for (final t in tasks.reversed) ...(t.isGroup ? t.children : [t])];
    final running = work.where((t) => t.status == DownloadStatus.running).length;
    if (running >= maxParallel) return;
    final next = work.where((t) => t.status == DownloadStatus.queued).firstOrNull;
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
      } else if (t.playlist && t.parent == null && !t.isGroup) {
        await _runPlaylist(t, work.path);
      } else {
        await _runYtDlp(t, work.path);
      }
    } catch (e) {
      if (t.status != DownloadStatus.cancelled) {
        t.status = DownloadStatus.failed;
        t.error = e is DioException ? _dioError(e) : e.toString();
        t.addLog('錯誤：${t.error}');
      }
    } finally {
      try {
        await work.delete(recursive: true);
      } catch (_) {}
    }
  }

  static String _dioError(DioException e) {
    final code = e.response?.statusCode;
    return [if (code != null) 'HTTP $code', e.message ?? e.type.name].join(' · ');
  }

  /// Moves a finished file into [outDir] (or keeps the existing copy if one
  /// with the same name is already there), adds it to the library and the
  /// task's playlist, and returns the library path.
  Future<String> _finish(DownloadTask t, String path) async {
    final target = p.join(outDir, p.basename(path));
    Track? track;
    if (File(target).existsSync()) {
      // Same file name = same song downloaded again: drop the new copy.
      await File(path).delete();
      t.duplicates++;
      t.addLog('已存在，刪除重複檔：${p.basename(path)}');
      track = await _db.track(target);
    } else {
      try {
        await File(path).rename(target);
      } on FileSystemException {
        // Different filesystem (app cache → shared storage): copy instead.
        await File(path).copy(target);
        await File(path).delete();
      }
    }
    track ??= await _scanner.importFile(target, source: TrackSource.download);
    t.files.add(target);
    final group = t.parent;
    if (track != null && group != null) {
      if (group.playlistId != null) await _db.addToPlaylistAt(group.playlistId!, track, group.playlistBase + t.index);
    } else if (track != null) {
      await _addToPlaylist(t, [track]);
    }
    return target;
  }

  /// Adds tracks to the task's playlist, creating it from the source
  /// playlist's title the first time when downloading a whole playlist.
  Future<void> _addToPlaylist(DownloadTask t, List<Track> tracks) async {
    if (t.playlistId == null) {
      final name = t.playlistName;
      if (!t.playlist || name == null) return;
      t.playlistId = await _db.createPlaylist(name);
      t.addLog('已建立播放清單「$name」');
    }
    await _db.addToPlaylist(t.playlistId!, tracks);
  }

  /// The source playlist's title arrived. If files finished before it (the
  /// Android backend can report it late), put those into the new playlist too.
  Future<void> _onPlaylistTitle(DownloadTask t, String title) async {
    if (t.playlistName != null) return;
    t.playlistName = title;
    if (t.playlistId != null || !t.playlist || t.files.isEmpty) return;
    final done = await _db.tracksByIds(t.files);
    await _addToPlaylist(t, done);
  }

  /// Lists the playlist (no download) and queues one child task per song.
  /// Falls back to one yt-dlp run for the whole list if the entries can't be
  /// downloaded on their own (e.g. no distinct per-song URLs).
  Future<void> _runPlaylist(DownloadTask t, String workDir) async {
    final backend = ytdlp;
    if (backend == null) throw '此平台不支援 yt-dlp';
    if (!await backend.isReady()) {
      await backend.prepare((s) {
        t.detail = s;
        _emit();
      });
    }
    t.detail = '讀取播放清單…';
    t.addLog('讀取播放清單：${t.url}');
    _emit();
    final entries = <int, PlaylistEntry>{};
    String? title;
    String? error;
    await for (final e in backend.run('${t.id}_list', t.url, playlistListArgs)) {
      switch (e) {
        case YtDlpPlaylistTitle():
          title ??= e.title;
        case YtDlpLog():
          final entry = PlaylistEntry.parse(e.line);
          if (entry != null) {
            entries[entry.index] = entry;
          } else {
            t.addLog(e.line);
          }
        case YtDlpFinished():
          if (!e.success) error = e.error;
        default:
      }
    }
    if (t.status == DownloadStatus.cancelled) return;
    final list = entries.values.toList()..sort((a, b) => a.index.compareTo(b.index));
    if (!canSplitPlaylist(list)) {
      t.addLog(list.isEmpty && error != null ? '讀取清單失敗：$error，改用整份下載' : '無法逐首下載，改用整份下載');
      return _runYtDlp(t, workDir);
    }
    title ??= t.playlistName;
    t.playlistName ??= title;
    if (t.title == t.url && title != null) t.title = title;
    // Library playlist: the one the user picked, or a new one named after the source.
    if (t.playlistId != null) {
      t.playlistBase = await _db.nextPlaylistPosition(t.playlistId!);
    } else if (t.playlistName != null) {
      t.playlistId = await _db.createPlaylist(t.playlistName!);
      t.addLog('已建立播放清單「${t.playlistName}」');
    }
    t.addLog('共 ${list.length} 首，同時下載 $maxParallel 首');
    for (final entry in list) {
      t.children.add(DownloadTask(
        id: '${t.id}_${entry.index}',
        url: entry.url,
        kind: DownloadKind.ytdlp,
        format: t.format,
        title: entry.title,
      )
        ..parent = t
        ..index = entry.index);
    }
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
    t.addLog('直接下載：${t.url}');
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
        ..title = t.url // let yt-dlp's file name become the title
        ..progress = 0
        ..detail = '改用 yt-dlp…';
      t.addLog('網址是網頁（$type），改用 yt-dlp');
      _emit();
      return _runYtDlp(t, workDir);
    }
    await _finish(t, part);
    t
      ..status = DownloadStatus.done
      ..progress = 1
      ..detail = _doneDetail(t);
  }

  static String _doneDetail(DownloadTask t) => [
        '${t.files.length} 個檔案',
        if (t.duplicates > 0) '${t.duplicates} 個已存在',
        if (t.playlistName != null && t.playlistId != null) '已加入「${t.playlistName}」',
      ].join(' · ');

  Future<void> _runYtDlp(DownloadTask t, String workDir) async {
    final backend = ytdlp;
    if (backend == null) throw '此平台不支援 yt-dlp';
    if (!await backend.isReady()) {
      await backend.prepare((s) {
        t.detail = s;
        t.addLog(s);
        _emit();
      });
    }
    final opts = YtDlpOptions(url: t.url, format: t.format, playlist: t.playlist, outDir: workDir);
    String? lastLog;
    await for (final e in backend.download(t.id, opts)) {
      switch (e) {
        case YtDlpProgress():
          // For playlists, progress covers the whole list, not just this song.
          t.progress = playlistProgress(e.percent, e.item, e.itemCount);
          t.detail = [
            if (e.itemCount != null) '第 ${e.item}/${e.itemCount} 首',
            '${(t.progress * 100).toStringAsFixed(1)}%',
            if (e.eta != null && e.eta != 'NA' && e.eta != 'Unknown') '剩餘 ${e.eta}',
          ].join('  ·  ');
          _emit();
        case YtDlpPlaylistTitle():
          await _onPlaylistTitle(t, e.title);
        case YtDlpFileDone():
          if (File(e.path).existsSync()) {
            if (t.title == t.url) t.title = t.playlist && t.playlistName != null ? t.playlistName! : p.basenameWithoutExtension(e.path);
            await _finish(t, e.path);
            _emit();
          }
        case YtDlpLog():
          lastLog = e.line;
          t.addLog(e.line);
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
              ..detail = _doneDetail(t);
          } else {
            t
              ..status = DownloadStatus.failed
              ..error = e.error ?? lastLog ?? '下載失敗';
            if (e.error != null) t.addLog('錯誤：${e.error}');
          }
      }
    }
  }
}

/// Overall progress (0..1) when song [item] of [count] is at [percent]%.
double playlistProgress(double percent, int? item, int? count) {
  final p = (percent / 100).clamp(0.0, 1.0);
  if (item == null || count == null || count <= 1) return p;
  return (((item - 1).clamp(0, count) + p) / count).clamp(0.0, 1.0);
}

/// yt-dlp arguments that only list a playlist's songs (nothing is downloaded).
const playlistListArgs = [
  '--flat-playlist',
  '--yes-playlist',
  '--print', 'OUOPLAYLIST %(playlist_title)s',
  '--print', 'OUOENTRY %(playlist_autonumber)s|%(url)s|%(title)s',
];

/// One song from a playlist listing.
class PlaylistEntry {
  final int index;
  final String url;
  final String title;
  const PlaylistEntry(this.index, this.url, this.title);

  /// Parses `OUOENTRY 3|https://…|Title` (the title may contain '|').
  static PlaylistEntry? parse(String line) {
    if (!line.startsWith('OUOENTRY ')) return null;
    final parts = line.substring(9).split('|');
    if (parts.length < 3) return null;
    final index = int.tryParse(parts[0].trim());
    final url = parts[1].trim();
    if (index == null) return null;
    return PlaylistEntry(index, url, parts.sublist(2).join('|').trim());
  }
}

/// Songs can be downloaded one by one only if each has its own web page
/// URL. Direct file links (e.g. Internet Archive) are left to one run over
/// the whole list, which keeps the site's proper song titles.
bool canSplitPlaylist(List<PlaylistEntry> entries) {
  if (entries.length < 2) return false;
  final urls = entries.map((e) => e.url).toSet();
  bool isFile(String u) {
    final path = Uri.tryParse(u)?.path.toLowerCase() ?? '';
    return audioExtensions.any(path.endsWith) || path.endsWith('.webm');
  }

  return urls.length == entries.length && urls.every((u) => u.startsWith('http') && !isFile(u));
}
