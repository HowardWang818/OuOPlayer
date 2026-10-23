import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';

/// Sends the current song and play state to the Android home screen widget
/// (PlayerWidgetProvider.kt). Windows has no widget.
final playerWidgetProvider = Provider<void>((ref) {
  if (!Platform.isAndroid) return;
  const channel = MethodChannel('ouo/widget');
  final track = ref.watch(currentTrackProvider);
  final playing = ref.watch(playbackStateProvider.select((s) => s.value?.playing ?? false));
  final art = track?.art;
  channel.invokeMethod('update', {
    'title': track?.title,
    'artist': track?.artist,
    // Only local cover files; online covers would need downloading.
    'art': art != null && !art.startsWith('http') ? art : null,
    'playing': playing,
  }).catchError((_) => null);
});
