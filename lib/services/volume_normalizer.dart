import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import '../providers/providers.dart';

/// mpv/ffmpeg dynamic normalizer: evens out loudness between and within songs.
const _windowsFilter = 'lavfi=[dynaudnorm=f=500:g=31:p=0.95:m=10]';

/// Keeps volume normalization in sync with the setting.
/// Windows: mpv audio filter. Android: DynamicsProcessing on the player's
/// audio session (NormalizerPlugin.kt), re-applied if the session changes.
final volumeNormalizationProvider = Provider<void>((ref) {
  final on = ref.watch(settingsProvider.select((s) => s.normalizeVolume));
  if (Platform.isWindows || Platform.isLinux) {
    JustAudioMediaKit.audioFilter = on ? _windowsFilter : '';
    return;
  }
  if (!Platform.isAndroid) return;
  const channel = MethodChannel('ouo/normalize');
  final player = ref.read(audioHandlerProvider).player;
  void apply(int? sessionId) {
    if (sessionId == null) return;
    channel.invokeMethod('set', {'sessionId': sessionId, 'enabled': on}).catchError((_) => false);
  }

  apply(player.androidAudioSessionId);
  final sub = player.androidAudioSessionIdStream.listen(apply);
  ref.onDispose(sub.cancel);
});
