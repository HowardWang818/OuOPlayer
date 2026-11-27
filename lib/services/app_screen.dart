import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

/// Whether the app's screen can be seen (a play without one syncs the list
/// queues first).
///
/// Started by the media service (widget, headset button, car) the app has no
/// lifecycle state at all: that is no screen, though it used to pass for one.
bool visibleIn(AppLifecycleState? state) => state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;

/// [visibleIn], and on Windows a window that is shown and not minimised (in
/// the tray, or started there, there is none).
Future<bool> appOnScreen() async {
  if (Platform.isWindows) {
    try {
      return await windowManager.isVisible() && !await windowManager.isMinimized();
    } catch (_) {
      // No window manager (tests): the lifecycle tells.
    }
  }
  return visibleIn(WidgetsBinding.instance.lifecycleState);
}
