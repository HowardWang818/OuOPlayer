import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Whether the phone is on mobile data right now (connected, but not over
/// Wi-Fi or Ethernet). Always false off Android.
Future<bool> onMobileData() async => await mobileDataNow() ?? false;

/// The phone's model (裝置名稱's default), null off Android or unknown.
Future<String?> phoneModel() async {
  if (!Platform.isAndroid) return null;
  try {
    return await const MethodChannel('ouo/network').invokeMethod<String>('model');
  } catch (_) {
    return null;
  }
}

/// [onMobileData], null when it can't be told. The channel is a plugin
/// (third_party/ouo_network): an app started in the background by the media
/// service has no MainActivity to answer.
Future<bool?> mobileDataNow() async {
  if (!Platform.isAndroid) return false;
  try {
    return await const MethodChannel('ouo/network').invokeMethod<bool>('mobileData');
  } catch (_) {
    return null;
  }
}

/// Whether songs may move by themselves: not on mobile data, and not when it
/// can't be told ([read]: for tests).
Future<bool> songsMayTransfer([Future<bool?> Function() read = mobileDataNow]) async => await read() == false;

/// The every-minute sync retry is skipped on mobile data (phone).
Future<bool> everyMinuteSkipped() => onMobileData();

/// Before a download: on mobile data, asks whether to go on ([warn] is the
/// 非 Wi-Fi 提醒 setting). Returns true to download.
/// [size]: how much will be downloaded (「約 62 MB」), when known.
Future<bool> okToDownload(BuildContext? context, {required bool warn, String? size}) async {
  if (!warn || !await onMobileData()) return true;
  if (context == null || !context.mounted) return true;
  final ok = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => AlertDialog(
      title: const Text('目前沒有連上 Wi-Fi'),
      content: Text('會使用行動數據下載${size == null ? '' : '（$size）'}，要繼續嗎？\n（可以在 設定 → 下載與線上 關掉這個提示）'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('繼續下載')),
      ],
    ),
  );
  return ok == true;
}
