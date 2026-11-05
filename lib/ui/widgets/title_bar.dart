import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../theme/app_theme.dart';
import 'blurred_cover.dart';
import 'song_font.dart';

/// Windows: the bar along the top of the window, in the app's own colours,
/// instead of the system's title bar. Drag it to move the window; double
/// click to maximise.
class TitleBar extends ConsumerStatefulWidget {
  const TitleBar({super.key});

  static const height = 32.0;

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
    final tint = ref.watch(titleBarTintProvider);
    final color = tint ?? AppTheme.palette(context).frame;
    final ink = tint == null ? theme.brightness : ThemeData.estimateBrightnessForColor(tint);
    final backdrop = ref.watch(titleBarBackdropProvider);
    return Material(
      type: MaterialType.transparency,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        height: TitleBar.height,
        color: backdrop == null ? color : Colors.transparent,
        child: Stack(children: [
          // The top of the player's blurred cover, the same picture as below.
          if (backdrop != null) Positioned.fill(child: BlurredCover(art: backdrop.art, veil: backdrop.veil)),
          Row(children: [
          const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
          WindowCaptionButton.minimize(brightness: ink, onPressed: windowManager.minimize),
          _maximized
              ? WindowCaptionButton.unmaximize(brightness: ink, onPressed: windowManager.unmaximize)
              : WindowCaptionButton.maximize(brightness: ink, onPressed: windowManager.maximize),
          WindowCaptionButton.close(brightness: ink, onPressed: windowManager.close),
          ]),
        ]),
      ),
    );
  }
}
