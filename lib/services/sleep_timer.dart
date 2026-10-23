import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import 'audio_handler.dart';

/// How long the volume fades out before the sleep timer pauses playback.
const sleepFade = Duration(seconds: 10);

/// Volume multiplier for the fade-out: 1.0 until the last [fade], then down to 0.
double fadeFactor(Duration remaining, {Duration fade = sleepFade}) =>
    (remaining.inMilliseconds / fade.inMilliseconds).clamp(0.0, 1.0);

class SleepTimerState {
  /// Set for a fixed-length timer; null for "播完這首".
  final DateTime? endsAt;
  final Duration? remaining;
  const SleepTimerState({this.endsAt, this.remaining});

  bool get endOfTrack => endsAt == null;
}

/// Pauses playback after a set time or at the end of the current track,
/// fading the volume out over the last [sleepFade].
class SleepTimerNotifier extends Notifier<SleepTimerState?> {
  Timer? _ticker;
  StreamSubscription<int?>? _indexSub;
  double? _savedVolume;

  @override
  SleepTimerState? build() {
    ref.onDispose(_stopInternals);
    return null;
  }

  OuoAudioHandler get _handler => ref.read(audioHandlerProvider);

  void start(Duration duration) {
    cancel();
    final endsAt = DateTime.now().add(duration);
    state = SleepTimerState(endsAt: endsAt, remaining: duration);
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final remaining = endsAt.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        _finish();
      } else {
        _fade(remaining);
        state = SleepTimerState(endsAt: endsAt, remaining: remaining);
      }
    });
  }

  void startEndOfTrack() {
    cancel();
    final player = _handler.player;
    final startIndex = player.currentIndex;
    state = const SleepTimerState();
    // The player has moved on to another track (or the queue ended): stop.
    _indexSub = player.currentIndexStream.listen((i) {
      if (i != startIndex) _finish();
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final d = player.duration;
      if (d == null) return;
      final remaining = d - player.position;
      _fade(remaining);
      state = SleepTimerState(remaining: remaining);
    });
  }

  void cancel() {
    final volume = _savedVolume;
    _stopInternals();
    if (volume != null) _handler.player.setVolume(volume);
    state = null;
  }

  void _fade(Duration remaining) {
    final f = fadeFactor(remaining);
    if (f >= 1) return;
    _savedVolume ??= _handler.player.volume;
    _handler.player.setVolume(_savedVolume! * f);
  }

  Future<void> _finish() async {
    final volume = _savedVolume;
    _stopInternals();
    state = null;
    await _handler.pause();
    if (volume != null) await _handler.player.setVolume(volume);
    // Pausing right as the next track starts can leave the notification and
    // lock screen on the previous title; send the current one again.
    final item = _handler.mediaItem.value;
    if (item != null) _handler.mediaItem.add(item);
  }

  void _stopInternals() {
    _ticker?.cancel();
    _ticker = null;
    _indexSub?.cancel();
    _indexSub = null;
    _savedVolume = null;
  }
}

final sleepTimerProvider = NotifierProvider<SleepTimerNotifier, SleepTimerState?>(SleepTimerNotifier.new);
