import 'dart:async';

import 'package:flutter/services.dart';

import 'ytdlp_downloader.dart';

/// Talks to YtDlpPlugin.kt, which wraps youtubedl-android (bundled Python,
/// yt-dlp and ffmpeg).
class YtDlpAndroid implements YtDlpBackend {
  static const _method = MethodChannel('ouo/ytdlp');
  static const _events = EventChannel('ouo/ytdlp/events');

  static Stream<Map>? _shared;
  Stream<Map> get _stream => _shared ??= _events.receiveBroadcastStream().cast<Map>().asBroadcastStream();

  @override
  Future<bool> isReady() async => (await _method.invokeMethod<bool>('init')) ?? false;

  @override
  Future<void> prepare(void Function(String status) onStatus) async {
    onStatus('初始化 yt-dlp…');
    await _method.invokeMethod('init');
    onStatus('完成');
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
          controller.add(YtDlpFinished(e['success'] == true, e['error'] as String?));
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
