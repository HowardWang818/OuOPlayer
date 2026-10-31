import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';

/// Light / dark: the moon while dark, the sun while light.
class ThemeButton extends ConsumerWidget {
  const ThemeButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return IconButton(
      icon: Icon(dark ? Icons.dark_mode_outlined : Icons.light_mode_outlined),
      tooltip: dark ? '切換成淺色' : '切換成深色',
      onPressed: () => ref.read(settingsProvider.notifier).setTheme(dark ? ThemeMode.light : ThemeMode.dark),
    );
  }
}
