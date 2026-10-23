import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ytdlp_downloader.dart';

/// Runs the official yt-dlp.exe (and ffmpeg) which are fetched on first use
/// from their GitHub releases into the app support folder.
class YtDlpWindows implements YtDlpBackend {
  static const _ytdlpUrl = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe';
  static const _ffmpegUrl = 'https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip';

  final _procs = <String, Process>{};

  Future<String> _binDir() async {
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'bin'));
    await dir.create(recursive: true);
    return dir.path;
  }

  Future<String> _ytdlp() async => p.join(await _binDir(), 'yt-dlp.exe');
  Future<String> _ffmpeg() async => p.join(await _binDir(), 'ffmpeg.exe');

  @override
  Future<bool> isReady() async => File(await _ytdlp()).existsSync() && File(await _ffmpeg()).existsSync();

  @override
  Future<void> prepare(void Function(String status) onStatus) async {
    final dio = Dio();
    final bin = await _binDir();
    final ytdlp = await _ytdlp();
    if (!File(ytdlp).existsSync()) {
      await dio.download(_ytdlpUrl, '$ytdlp.part', onReceiveProgress: (r, t) {
        if (t > 0) onStatus('下載 yt-dlp… ${(r * 100 / t).toStringAsFixed(0)}%');
      });
      await File('$ytdlp.part').rename(ytdlp);
    }
    final ffmpeg = await _ffmpeg();
    if (!File(ffmpeg).existsSync()) {
      final zip = p.join(bin, 'ffmpeg.zip');
      await dio.download(_ffmpegUrl, zip, onReceiveProgress: (r, t) {
        if (t > 0) onStatus('下載 ffmpeg… ${(r * 100 / t).toStringAsFixed(0)}%');
      });
      onStatus('解壓縮 ffmpeg…');
      final input = InputFileStream(zip);
      final archive = ZipDecoder().decodeStream(input);
      for (final f in archive.files) {
        final name = p.basename(f.name);
        if (f.isFile && (name == 'ffmpeg.exe' || name == 'ffprobe.exe')) {
          final out = OutputFileStream(p.join(bin, name));
          f.writeContent(out);
          await out.close();
        }
      }
      await input.close();
      await File(zip).delete();
    }
    onStatus('完成');
  }

  @override
  Future<String?> version() async {
    final exe = await _ytdlp();
    if (!File(exe).existsSync()) return null;
    final r = await Process.run(exe, ['--version']);
    return (r.stdout as String).trim();
  }

  @override
  Future<String> update() async {
    final exe = await _ytdlp();
    final r = await Process.run(exe, ['-U'], stdoutEncoding: utf8, stderrEncoding: utf8);
    final out = '${r.stdout}\n${r.stderr}'.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
    return out.isEmpty ? '已更新' : out.last;
  }

  @override
  Stream<YtDlpEvent> download(String jobId, YtDlpOptions options) => run(jobId, options.url, options.args);

  @override
  Stream<YtDlpEvent> run(String jobId, String url, List<String> args) {
    final controller = StreamController<YtDlpEvent>();
    () async {
      final parser = YtDlpLineParser();
      final errors = <String>[];
      try {
        final proc = await Process.start(
          await _ytdlp(),
          [...args, '--ffmpeg-location', await _binDir(), '--encoding', 'utf-8', url],
          environment: {'PYTHONIOENCODING': 'utf-8', 'PYTHONUTF8': '1'},
        );
        _procs[jobId] = proc;
        final output = StringBuffer();
        final outDone = proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach((l) {
          output.writeln(l);
          final e = parser.parse(l);
          if (e != null) controller.add(e);
        });
        final errDone = proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).forEach((l) {
          if (l.contains('ERROR')) errors.add(l);
          final e = parser.parse(l);
          if (e != null) controller.add(e);
        });
        final code = await proc.exitCode;
        await Future.wait([outDone, errDone]);
        final cancelled = !_procs.containsKey(jobId);
        controller.add(YtDlpFinished(code == 0, cancelled ? '已取消' : (errors.isEmpty ? null : errors.last), output.toString()));
      } catch (e) {
        controller.add(YtDlpFinished(false, e.toString()));
      } finally {
        _procs.remove(jobId);
        await controller.close();
      }
    }();
    return controller.stream;
  }

  @override
  Future<void> cancel(String jobId) async {
    final proc = _procs.remove(jobId);
    if (proc == null) return;
    // Kill the whole tree so ffmpeg children stop too.
    await Process.run('taskkill', ['/PID', '${proc.pid}', '/T', '/F']);
  }
}
