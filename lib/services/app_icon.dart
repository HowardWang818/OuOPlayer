import 'dart:io';

import 'package:flutter/services.dart';

/// The home screen icon: dark (default) or light. Android only — it switches
/// between two activity-aliases (IconPlugin.kt); Windows keeps the icon its
/// .exe was built with.
class AppIcon {
  static const _channel = MethodChannel('ouo/icon');

  static bool get supported => Platform.isAndroid;

  static Future<bool> isLight() async => await _channel.invokeMethod<bool>('isLight') ?? false;

  static Future<void> setLight(bool light) async {
    try {
      await _channel.invokeMethod('setLight', light);
    } on PlatformException catch (e) {
      throw e.message ?? '無法更換圖示';
    }
  }
}
