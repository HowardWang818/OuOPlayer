import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import 'network_check.dart';

/// How often yt-dlp is updated by itself (YouTube changes often, and old
/// versions start failing).
const ytDlpUpdateEvery = Duration(days: 7);

/// Whether an automatic update is due.
bool ytDlpUpdateDue(DateTime? last, DateTime now) => last == null || now.difference(last) >= ytDlpUpdateEvery;

/// Shortly after start-up: updates yt-dlp in the background when a week has
/// passed, nothing is downloading, and (with the 非 Wi-Fi 提醒 on) only over
/// Wi-Fi. [notify] shows the result.
Future<void> autoUpdateYtDlp(WidgetRef ref, void Function(String message) notify) async {
  final s = ref.read(settingsProvider);
  if (!s.ytAutoUpdate || !ytDlpUpdateDue(s.ytLastUpdate, DateTime.now())) return;
  final svc = ref.read(downloadServiceProvider);
  final yt = svc.ytdlp;
  if (yt == null || svc.tasks.any((t) => t.active)) return;
  if (s.wifiWarning && await onMobileData()) return;
  try {
    // Not installed yet (Windows before the first download): nothing to update.
    if (!await yt.isReady()) return;
    final before = await yt.version();
    final msg = await yt.update();
    ref.read(settingsProvider.notifier).setYtLastUpdate(DateTime.now());
    final after = await yt.version();
    if (after != null && after != before) notify('yt-dlp 已自動更新到 $after');
    debugPrint('yt-dlp auto update: $msg');
  } catch (e) {
    // Try again next start-up; don't bother the user.
    debugPrint('yt-dlp auto update failed: $e');
  }
}
