import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../data/db/database.dart';
import 'audio_handler.dart';

/// Windows, when 關閉視窗時縮到系統匣 is on (設定 → 播放): closing the window
/// keeps OuOPlayer in the system tray (music and sync go on); the tray icon
/// brings it back, plays / pauses or quits. Off (the default): closing quits.
class DesktopTray with TrayListener, WindowListener {
  DesktopTray._(this.handler);
  final OuoAudioHandler handler;
  static DesktopTray? _instance;
  bool _on = false;

  static Future<void> init(OuoAudioHandler handler, AppDatabase db, List<String> args) async {
    if (!Platform.isWindows) return;
    await windowManager.ensureInitialized();
    final tray = _instance = DesktopTray._(handler);
    windowManager.addListener(tray);
    trayManager.addListener(tray);
    final settings = await db.allSettings();
    final on = settings['close_to_tray'] == 'true';
    await tray._set(on);
    // The app may have moved since (the zip's folder, then the installed one).
    if (settings['start_with_windows'] == 'true') await setStartWithWindows(true);
    // 開機時自動啟動 with the tray on: start in the tray.
    if (on && args.contains('--tray')) await windowManager.hide();
  }

  /// Saves where playback is and ends the app.
  static Future<void> quit() async {
    await _instance?.handler.saveSession();
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
    exit(0);
  }

  /// Songs on their way, in the tray icon's tooltip (null: just OuOPlayer).
  static Future<void> setStatus(String? text) async {
    final t = _instance;
    if (t == null || !t._on) return;
    try {
      await trayManager.setToolTip(text == null ? 'OuOPlayer' : 'OuOPlayer：$text');
    } catch (_) {}
  }

  /// Turns the tray on / off now (the setting changed).
  static Future<void> setEnabled(bool on) async => _instance?._set(on);

  /// 開機時自動啟動: the user's Run key starts OuOPlayer at sign-in (in the
  /// tray when 關閉視窗時縮到系統匣 is on).
  static Future<void> setStartWithWindows(bool on) async {
    const key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
    if (on) {
      await Process.run('reg', ['add', key, '/v', 'OuOPlayer', '/t', 'REG_SZ', '/d', '"${Platform.resolvedExecutable}" --tray', '/f']);
    } else {
      await Process.run('reg', ['delete', key, '/v', 'OuOPlayer', '/f']);
    }
  }

  Future<void> _set(bool on) async {
    _on = on;
    await windowManager.setPreventClose(on);
    if (on) {
      await trayManager.setIcon('assets/icon/tray.ico');
      await trayManager.setToolTip('OuOPlayer');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: '顯示 OuOPlayer'),
        MenuItem(key: 'play', label: '播放／暫停'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: '結束'),
      ]));
    } else {
      await trayManager.destroy();
    }
  }

  Future<void> _show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onWindowClose() {
    if (_on) windowManager.hide();
  }

  @override
  void onTrayIconMouseDown() => _show();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        _show();
      case 'play':
        handler.player.playing ? handler.pause() : handler.play();
      case 'quit':
        quit();
    }
  }
}
