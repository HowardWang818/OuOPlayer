import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';

/// Text and button colour on a widget background: white on dark covers,
/// black on light ones (the same rule as the in-app player bar).
Color widgetForeground(Color background) =>
    ThemeData.estimateBrightnessForColor(background) == Brightness.dark ? Colors.white : Colors.black87;

/// Sends the current song, play state and cover colour to the Android home
/// screen widget (PlayerWidgetProvider.kt). Windows has no widget.
final playerWidgetProvider = Provider<void>((ref) {
  if (!Platform.isAndroid) return;
  const channel = MethodChannel('ouo/widget');
  final track = ref.watch(currentTrackProvider);
  final playing = ref.watch(playbackStateProvider.select((s) => s.value?.playing ?? false));
  final art = track?.art;
  // The colour the player bar uses; null until worked out (or no cover).
  final bg = ref.watch(artColorProvider(art)).value?.withValues(alpha: 1);
  channel.invokeMethod('update', {
    'title': track?.title,
    'artist': track?.artist,
    // Only local cover files; online covers would need downloading.
    'art': art != null && !art.startsWith('http') ? art : null,
    'playing': playing,
    'bg': bg?.toARGB32(),
    'fg': bg == null ? null : widgetForeground(bg).toARGB32(),
  }).catchError((_) => null);
});
