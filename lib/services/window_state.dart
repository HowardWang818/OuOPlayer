import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../data/db/database.dart';
import '../providers/providers.dart';

/// Windows: the window comes back where it was, as big as it was.
class WindowState with WindowListener {
  WindowState._(this.db);
  final AppDatabase db;
  Timer? _save;

  static const minimum = Size(800, 560);

  static Future<void> init(AppDatabase db) async {
    if (!Platform.isWindows) return;
    await windowManager.ensureInitialized();
    await windowManager.setMinimumSize(minimum);
    // The app draws its own bar (TitleBar), in its own colours.
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
    final s = await db.allSettings();
    try {
      final j = jsonDecode(s['window_bounds'] ?? '') as Map;
      final bounds = Rect.fromLTWH((j['x'] as num).toDouble(), (j['y'] as num).toDouble(),
          max((j['w'] as num).toDouble(), minimum.width), max((j['h'] as num).toDouble(), minimum.height));
      // The screen it was on may be gone: then only its size comes back.
      final displays = await screenRetriever.getAllDisplays();
      final seen = displays.any((d) {
        final at = d.visiblePosition ?? Offset.zero;
        return (at & (d.visibleSize ?? d.size)).contains(bounds.center);
      });
      if (seen) {
        await windowManager.setBounds(bounds);
      } else {
        await windowManager.setSize(bounds.size);
        await windowManager.center();
      }
    } catch (_) {}
    if (s['window_maximized'] == 'true') await windowManager.maximize();
    windowManager.addListener(WindowState._(db));
  }

  void _later() {
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 500), () async {
      if (await windowManager.isMaximized() || await windowManager.isMinimized()) return;
      final b = await windowManager.getBounds();
      await db.setSetting('window_bounds', jsonEncode({'x': b.left, 'y': b.top, 'w': b.width, 'h': b.height}));
    });
  }

  @override
  void onWindowResize() => _later();
  @override
  void onWindowMove() => _later();
  @override
  void onWindowMaximize() => db.setSetting('window_maximized', 'true');
  @override
  void onWindowUnmaximize() => db.setSetting('window_maximized', 'false');
}

/// Windows: the widths of the left column and the right panel, and the height
/// of the top left block, dragged by their dividers and remembered.
class DesktopLayout {
  const DesktopLayout({this.left = 280, this.nav = 340, this.right = 340, this.queue = 220, this.lyrics = true});

  /// [queue]: the height of the queue block under the right panel.
  final double left, nav, right, queue;

  /// Lyrics shown in the right panel (hidden: more of the queue instead).
  final bool lyrics;

  static const leftMin = 200.0, leftMax = 400.0, rightMin = 280.0, rightMax = 480.0, centerMin = 400.0, navMin = 120.0, gap = 8.0;
  static const queueMin = 120.0, songMin = 240.0;

  DesktopLayout copyWith({double? left, double? nav, double? right, double? queue, bool? lyrics}) => DesktopLayout(
      left: left ?? this.left, nav: nav ?? this.nav, right: right ?? this.right, queue: queue ?? this.queue, lyrics: lyrics ?? this.lyrics);
}

class DesktopLayoutNotifier extends Notifier<DesktopLayout> {
  @override
  DesktopLayout build() {
    _load();
    return const DesktopLayout();
  }

  Future<void> _load() async {
    final s = await ref.read(dbProvider).allSettings();
    double? v(String k) => double.tryParse(s[k] ?? '');
    state = DesktopLayout(
      left: v('ui_left') ?? state.left,
      nav: v('ui_nav') ?? state.nav,
      right: v('ui_right') ?? state.right,
      queue: v('ui_queue') ?? state.queue,
      lyrics: s['ui_lyrics'] != 'false',
    );
  }

  void setLeft(double v) => state = state.copyWith(left: v);
  void setNav(double v) => state = state.copyWith(nav: v);
  void setRight(double v) => state = state.copyWith(right: v);
  void setQueue(double v) => state = state.copyWith(queue: v);

  void toggleLyrics() {
    state = state.copyWith(lyrics: !state.lyrics);
    ref.read(dbProvider).setSetting('ui_lyrics', '${state.lyrics}');
  }

  Future<void> save() async {
    final db = ref.read(dbProvider);
    await db.setSetting('ui_left', '${state.left}');
    await db.setSetting('ui_nav', '${state.nav}');
    await db.setSetting('ui_right', '${state.right}');
    await db.setSetting('ui_queue', '${state.queue}');
  }
}

final desktopLayoutProvider = NotifierProvider<DesktopLayoutNotifier, DesktopLayout>(DesktopLayoutNotifier.new);
