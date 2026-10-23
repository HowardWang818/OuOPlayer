import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/sleep_timer.dart';
import '../../theme/app_theme.dart';
import 'art_image.dart';

String sleepTimerLabel(SleepTimerState? s) {
  if (s == null) return '關閉';
  if (s.endOfTrack) return '播完這首後停止';
  return '剩餘 ${formatDuration(s.remaining)}';
}

Future<void> showSleepTimerSheet(BuildContext context, WidgetRef ref) {
  final timer = ref.read(sleepTimerProvider.notifier);
  final active = ref.read(sleepTimerProvider) != null;
  return showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (ctx) {
      void pick(VoidCallback action) {
        Navigator.pop(ctx);
        action();
      }

      return SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('睡眠計時器', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18))),
          for (final m in [15, 30, 45, 60])
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: Text('$m 分鐘'),
              onTap: () => pick(() => timer.start(Duration(minutes: m))),
            ),
          ListTile(
            leading: const Icon(Icons.music_off_outlined),
            title: const Text('播完這首'),
            onTap: () => pick(timer.startEndOfTrack),
          ),
          if (active)
            ListTile(
              leading: const Icon(Icons.timer_off_outlined, color: AppColors.accent),
              title: const Text('關閉計時器', style: TextStyle(color: AppColors.accent)),
              onTap: () => pick(timer.cancel),
            ),
        ]),
      );
    },
  );
}

/// Moon button for the Now Playing page; turns accent-coloured while a timer runs.
class SleepTimerButton extends ConsumerWidget {
  const SleepTimerButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sleepTimerProvider);
    final icon = Icon(Icons.bedtime_outlined, color: s == null ? null : AppColors.accent);
    if (s == null) return IconButton(tooltip: '睡眠計時器', icon: icon, onPressed: () => showSleepTimerSheet(context, ref));
    return TextButton.icon(
      onPressed: () => showSleepTimerSheet(context, ref),
      icon: icon,
      label: Text(s.endOfTrack ? '本首結束' : formatDuration(s.remaining), style: const TextStyle(color: AppColors.accent)),
    );
  }
}
