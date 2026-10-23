import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import '../providers/providers.dart';

/// mpv/ffmpeg dynamic normalizer per strength: evens out loudness between and
/// within songs. `p` is the target peak, `m` the maximum gain, `g` the smoothing.
String windowsNormalizeFilter(NormalizeLevel level) => switch (level) {
      NormalizeLevel.quiet => 'lavfi=[dynaudnorm=f=500:g=31:p=0.6:m=6]',
      NormalizeLevel.normal => 'lavfi=[dynaudnorm=f=500:g=31:p=0.9:m=10]',
      NormalizeLevel.loud => 'lavfi=[dynaudnorm=f=300:g=15:p=0.98:m=20]',
    };

/// Keeps volume normalization in sync with the settings.
/// Windows: mpv audio filter. Android: DynamicsProcessing on the player's
/// audio session (NormalizerPlugin.kt), re-applied if the session changes.
final volumeNormalizationProvider = Provider<void>((ref) {
  final on = ref.watch(settingsProvider.select((s) => s.normalizeVolume));
  final level = ref.watch(settingsProvider.select((s) => s.normalizeLevel));
  if (Platform.isWindows || Platform.isLinux) {
    JustAudioMediaKit.audioFilter = on ? windowsNormalizeFilter(level) : '';
    return;
  }
  if (!Platform.isAndroid) return;
  const channel = MethodChannel('ouo/normalize');
  final player = ref.read(audioHandlerProvider).player;
  void apply(int? sessionId) {
    if (sessionId == null) return;
    channel.invokeMethod('set', {'sessionId': sessionId, 'enabled': on, 'level': level.name}).catchError((_) => false);
  }

  apply(player.androidAudioSessionId);
  final sub = player.androidAudioSessionIdStream.listen(apply);
  ref.onDispose(sub.cancel);
});
