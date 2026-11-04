import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../app.dart' show rootNavigatorKey;
import '../../config/update_config.dart';
import 'ytdlp_downloader.dart';

/// The archives left out of the APK (v1.15.0), per ABI: (bytes, SHA-256).
/// They are youtubedl-android 0.18.1's libpython.zip.so / libffmpeg.zip.so,
/// on the update server as `components/ytdlp-0.18.1/<abi>/<name>.zip`; a new
/// library version needs new files there and new values here.
const ytdlpComponentVersion = 'ytdlp-0.18.1';
const ytdlpComponents = <String, Map<String, (int, String)>>{
  'arm64-v8a': {
    'python': (14305904, '7edecb6c9bd3a94456168d44911d8aea9f917bedef90c320a29500d92ac3eb62'),
    'ffmpeg': (35624931, '4664a895283f9f31786be39b0c484c1f96631f02c7c7f9c70a4a4a2da324a092'),
  },
  'armeabi-v7a': {
    'python': (12822487, '4d860f1434442c69f128279705806916def2b323d1b43b7fa6ada7dfab0a0571'),
    'ffmpeg': (30476956, '5b4a436358e28fc0f0788f5f917dcce9d35c0107b7454ca78dda3191e6dc120c'),
  },
  'x86_64': {
    'python': (14302766, '27caa316e09681ada860fdb6b35c1914e541e266e674141361758ac127fe2f15'),
    'ffmpeg': (38595503, '79a442979bfc0363fcdd7e47f75daf022891e84fc01f3fdd866af785d22321ef'),
  },
};

/// Talks to YtDlpPlugin.kt, which wraps youtubedl-android (Python, yt-dlp
/// and ffmpeg; Python's and ffmpeg's files are fetched on first use).
class YtDlpAndroid implements YtDlpBackend {
  static const _method = MethodChannel('ouo/ytdlp');
  static const _events = EventChannel('ouo/ytdlp/events');

  static Stream<Map>? _shared;
  Stream<Map> get _stream => _shared ??= _events.receiveBroadcastStream().cast<Map>().asBroadcastStream();

  Future<List<String>> _missing() async => (await _method.invokeListMethod<String>('components')) ?? const [];

  @override
  Future<bool> isReady() async {
    if ((await _missing()).isNotEmpty) return false;
    return (await _method.invokeMethod<bool>('init')) ?? false;
  }

  /// First use: asks, then fetches Python's and ffmpeg's files (checked
  /// against [ytdlpComponents]) and has the plugin unpack them.
  @override
  Future<void> prepare(void Function(String status) onStatus) => _preparing ??= _prepare(onStatus).whenComplete(() => _preparing = null);

  /// Several downloads waiting share one fetch.
  static Future<void>? _preparing;

  Future<void> _prepare(void Function(String status) onStatus) async {
    final missing = await _missing();
    if (missing.isNotEmpty) {
      final abi = await _method.invokeMethod<String>('abi');
      final parts = ytdlpComponents[abi];
      if (parts == null) throw '這支手機的處理器不支援下載功能';
      final total = missing.fold<int>(0, (a, n) => a + parts[n]!.$1);
      if (!await _ask(total)) throw '已取消：要先下載下載元件，才能下載歌曲';
      final dir = await getTemporaryDirectory();
      final dio = Dio();
      for (final name in missing) {
        final (size, sha) = parts[name]!;
        final file = File(p.join(dir.path, 'ouo_$name.zip'));
        final label = name == 'python' ? 'Python' : 'ffmpeg';
        try {
          await dio.download('$updateServer/components/$ytdlpComponentVersion/$abi/$name.zip', file.path,
              options: Options(headers: updateHeaders), onReceiveProgress: (r, t) {
            if (size > 0) onStatus('下載元件 $label… ${(r * 100 / size).clamp(0, 100).toStringAsFixed(0)}%');
          });
          onStatus('檢查元件 $label…');
          if (await file.length() != size || (await sha256.bind(file.openRead()).first).toString() != sha) {
            throw '下載的元件不完整，請再試一次';
          }
          onStatus('安裝元件 $label…');
          await _method.invokeMethod('installComponent', {'name': name, 'zip': file.path});
        } finally {
          if (file.existsSync()) await file.delete();
        }
      }
    }
    onStatus('初始化 yt-dlp…');
    await _method.invokeMethod('init');
    onStatus('完成');
  }

  /// Once, before the first download: the files are about 50 MB.
  static Future<bool> _ask(int bytes) async {
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return true; // nobody to ask: the user started a download
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: const Text('先下載下載元件？'),
        content: Text('第一次使用下載功能，要先下載約 ${(bytes / (1 << 20)).round()} MB 的元件（Python 和 ffmpeg），只需要一次。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(autofocus: true, onPressed: () => Navigator.pop(c, true), child: const Text('下載')),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Future<String?> version() => _method.invokeMethod<String>('version');

  @override
  Future<String> update() async => (await _method.invokeMethod<String>('update')) ?? '已更新';

  @override
  Stream<YtDlpEvent> download(String jobId, YtDlpOptions options) => run(jobId, options.url, options.args);

  @override
  Stream<YtDlpEvent> run(String jobId, String url, List<String> args) {
    final controller = StreamController<YtDlpEvent>();
    final parser = YtDlpLineParser();
    late StreamSubscription sub;
    sub = _stream.where((e) => e['id'] == jobId).listen((e) {
      switch (e['type']) {
        case 'line':
          final ev = parser.parse(e['line'] as String? ?? '');
          if (ev != null) controller.add(ev);
        case 'done':
          // Lines the callback missed (e.g. --print output) are in the final stdout.
          for (final l in (e['out'] as String? ?? '').split('\n')) {
            final ev = parser.parse(l);
            if (ev is YtDlpFileDone || ev is YtDlpPlaylistTitle || (ev is YtDlpLog && ev.line.startsWith('OUOENTRY '))) {
              controller.add(ev!);
            }
          }
          controller.add(YtDlpFinished(e['success'] == true, e['error'] as String?, e['out'] as String?));
          sub.cancel();
          controller.close();
      }
    });
    _method.invokeMethod('download', {'id': jobId, 'url': url, 'args': args}).catchError((Object err) {
      controller.add(YtDlpFinished(false, err.toString()));
      sub.cancel();
      controller.close();
      return null;
    });
    return controller.stream;
  }

  @override
  Future<void> cancel(String jobId) => _method.invokeMethod('cancel', {'id': jobId});
}
