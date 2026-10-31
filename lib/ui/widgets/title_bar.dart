import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'song_font.dart';

/// Windows: the bar along the top of the window, in the app's own colours,
/// instead of the system's title bar. Drag it to move the window; double
/// click to maximise.
class TitleBar extends ConsumerStatefulWidget {
  const TitleBar({super.key});

  @override
  ConsumerState<TitleBar> createState() => _TitleBarState();
}

class _TitleBarState extends ConsumerState<TitleBar> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((v) {
      if (mounted) setState(() => _maximized = v);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);
  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final tint = ref.watch(titleBarTintProvider);
    final color = tint ?? (dark ? Colors.black : theme.colorScheme.surfaceContainer);
    final ink = tint == null ? theme.brightness : ThemeData.estimateBrightnessForColor(tint);
    return Material(
      type: MaterialType.transparency,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        height: 32,
        color: color,
        child: Row(children: [
          const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
          WindowCaptionButton.minimize(brightness: ink, onPressed: windowManager.minimize),
          _maximized
              ? WindowCaptionButton.unmaximize(brightness: ink, onPressed: windowManager.unmaximize)
              : WindowCaptionButton.maximize(brightness: ink, onPressed: windowManager.maximize),
          WindowCaptionButton.close(brightness: ink, onPressed: windowManager.close),
        ]),
      ),
    );
  }
}
