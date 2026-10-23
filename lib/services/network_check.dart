import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Whether the phone is on mobile data right now (connected, but not over
/// Wi-Fi or Ethernet). Always false off Android.
Future<bool> onMobileData() async {
  if (!Platform.isAndroid) return false;
  try {
    return await const MethodChannel('ouo/network').invokeMethod<bool>('mobileData') ?? false;
  } catch (_) {
    return false;
  }
}

/// Before a download: on mobile data, asks whether to go on ([warn] is the
/// 非 Wi-Fi 提醒 setting). Returns true to download.
Future<bool> okToDownload(BuildContext? context, {required bool warn}) async {
  if (!warn || !await onMobileData()) return true;
  if (context == null || !context.mounted) return true;
  final ok = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => AlertDialog(
      title: const Text('目前沒有連上 Wi-Fi'),
      content: const Text('會使用行動數據下載，要繼續嗎？\n（可以在 設定 → 下載 關掉這個提示）'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('繼續下載')),
      ],
    ),
  );
  return ok == true;
}
