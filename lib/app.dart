import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/providers.dart';
import 'theme/app_theme.dart';
import 'ui/shell/app_shell.dart';

class OuoApp extends ConsumerWidget {
  const OuoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(settingsProvider.select((s) => s.themeMode));
    ref.watch(bluetoothAutomationProvider);
    ref.watch(shareIntentProvider);
    return MaterialApp(
      title: 'OuOPlayer',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: mode,
      home: const AppShell(),
    );
  }
}

/// Android "share to OuOPlayer": queue the first URL in the shared text.
final shareIntentProvider = Provider<void>((ref) {
  if (!Platform.isAndroid) return;
  // Needed for the playback and download notifications on Android 13+.
  Permission.notification.request();
  const channel = MethodChannel('ouo/share');
  void handle(String? text) {
    final url = RegExp(r'https?://\S+').firstMatch(text ?? '')?.group(0);
    if (url == null) return;
    ref.read(downloadServiceProvider).add(url, format: ref.read(settingsProvider).ytFormat);
    ref.read(tabProvider.notifier).set(3);
  }

  channel.setMethodCallHandler((call) async {
    if (call.method == 'shared') handle(call.arguments as String?);
  });
  channel.invokeMethod<String>('initialText').then(handle).catchError((_) {});
});

/// Bluetooth audio connected → resume (if enabled). Disconnects are handled by
/// the audio session's "becoming noisy" event inside the audio handler.
final bluetoothAutomationProvider = Provider<void>((ref) {
  final bt = ref.watch(bluetoothProvider);
  if (!bt.supported) return;
  final sub = bt.audioConnected.listen((_) async {
    if (!ref.read(settingsProvider).btAutoPlay) return;
    // Give Android a moment to route audio to the headset.
    await Future.delayed(const Duration(milliseconds: 1500));
    await ref.read(audioHandlerProvider).play();
  });
  ref.onDispose(sub.cancel);
});
