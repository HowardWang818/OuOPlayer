import 'dart:async';
import 'dart:math';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import '../data/models/track.dart';
import '../providers/providers.dart';
import 'equalizer.dart';
import 'loudness.dart';

/// Windows (mpv) sound chain: built once, then only its values change, live
/// (`af-command`), so moving an EQ slider or switching the normalization
/// level never rebuilds the chain (that rebuild was the stutter, and it
/// restarted the normalizer, so levels sounded the same).
///
/// Normalizer → level → headroom → 5-band EQ → limiter:
/// - dynaudnorm with `g=51` frames of smoothing: with less, the gain follows
///   drums and voices wobble (measured: 6× the original wobble with the old
///   `g=31`, none with 51). It looks ~25 s ahead (under 0.1 s for local
///   files). Off = peak 1 and max gain 1, which leaves the sound as it is.
/// - level: quiet −8 dB, normal 0, loud +4 dB. Since v0.10.0, songs measured
///   with ffmpeg get one fixed gain instead ([songGainDb]) and dynaudnorm is
///   off: it lowered choruses and didn't even out songs.
/// - headroom: half the biggest EQ boost, so boosts stay audible.
/// - limiter with a slow release, so it catches peaks without pumping.
const windowsLimiter = 'alimiter=limit=0.95:attack=10:release=300:level=0';

/// The live values for the settings: (filter, option, value).
List<(String, String, String)> windowsFilterValues(
    {required bool normalize, required NormalizeLevel level, List<double>? eq, double? songGainDb}) {
  final gains = eq ?? List.filled(eqFrequencies.length, 0.0);
  final boost = max(0.0, gains.reduce(max));
  final adaptive = normalize && songGainDb == null;
  return [
    ('dynaudnorm@norm', 'p', adaptive ? '0.8' : '1'),
    ('dynaudnorm@norm', 'm', !adaptive ? '1' : switch (level) { NormalizeLevel.quiet => '4', NormalizeLevel.normal => '8', NormalizeLevel.loud => '12' }),
    (
      'volume@level',
      'volume',
      !normalize
          ? '0dB'
          : songGainDb != null
              ? '${songGainDb.toStringAsFixed(1)}dB'
              : switch (level) { NormalizeLevel.quiet => '-8dB', NormalizeLevel.normal => '0dB', NormalizeLevel.loud => '4dB' }
    ),
    ('volume@headroom', 'volume', '-${(boost / 2).toStringAsFixed(1)}dB'),
    for (var i = 0; i < eqFrequencies.length; i++) ('equalizer@b$i', 'g', gains[i].toStringAsFixed(1)),
  ];
}

/// A song's gain on Windows, in two parts. Lowering goes to mpv's
/// `volume-gain` (after the chain), which holds from song to song, so a new
/// song starts no louder than it should without rebuilding the chain. Raising
/// stays in the chain, ahead of the limiter that rounds off the raised peaks.
({double chain, double output}) windowsGain(double gain) => (chain: max(gain, 0.0), output: min(gain, 0.0));

/// The mpv `af` text for the chain, starting at [values].
String windowsFilterChain(List<(String, String, String)> values) {
  String v(String target, String option) => values.firstWhere((x) => x.$1 == target && x.$2 == option).$3;
  return '@ouo:lavfi=[${[
    'dynaudnorm@norm=f=500:g=51:p=${v('dynaudnorm@norm', 'p')}:m=${v('dynaudnorm@norm', 'm')}',
    'volume@level=volume=${v('volume@level', 'volume')}',
    'volume@headroom=volume=${v('volume@headroom', 'volume')}',
    for (var i = 0; i < eqFrequencies.length; i++) 'equalizer@b$i=f=${eqFrequencies[i]}:t=o:w=2:g=${v('equalizer@b$i', 'g')}',
    'alimiter@limit=${windowsLimiter.substring('alimiter='.length)}',
  ].join(',')}]';
}

final loudnessProvider = Provider<LoudnessService>((ref) => LoudnessService(ref.watch(dbProvider)));

/// The 音量平衡 gain of the playing song (dB), null while unknown. Measured
/// songs get one fixed gain each; songs that can't be measured (streams,
/// podcasts) play as they are.
class SongGainNotifier extends Notifier<double?> {
  @override
  double? build() {
    final on = ref.watch(settingsProvider.select((s) => s.normalizeVolume));
    final level = ref.watch(settingsProvider.select((s) => s.normalizeLevel));
    final track = ref.watch(currentTrackProvider);
    if (!on || track == null || !LoudnessService.measurable(track)) return null;
    final service = ref.read(loudnessProvider);
    var alive = true;
    ref.onDispose(() => alive = false);
    () async {
      // Without ffmpeg (Windows), the adaptive normalizer stays.
      if (!await service.available) return;
      final saved = await service.saved(track);
      if (saved != null) {
        if (alive) state = songGain(saved, level);
      } else {
        if (alive) state = unmeasuredGain(level);
        final l = await service.get(track, urgent: true);
        if (alive && l != null) state = songGain(l, level);
      }
      // The next song gets measured before it comes up.
      final handler = ref.read(audioHandlerProvider);
      final next = handler.nextTrack;
      if (next != null) unawaited(service.get(next, urgent: true));
      unawaited(service.scanLibrary());
    }();
    // Keep the last song's gain until this one's is known (usually at once, from the library).
    return stateOrNull;
  }
}

final songGainProvider = NotifierProvider<SongGainNotifier, double?>(SongGainNotifier.new);

/// Changes the gain over about a second instead of jumping (a song measured
/// while it already plays).
class _GainRamp {
  double current = 0;
  Timer? _timer;
  void to(double target, void Function(double) send, {bool instant = false}) {
    _timer?.cancel();
    if (instant || (target - current).abs() < 0.5) {
      current = target;
      send(target);
      return;
    }
    final from = current;
    var step = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 100), (t) {
      step++;
      current = from + (target - from) * step / 10;
      send(current);
      if (step >= 10) t.cancel();
    });
  }
}

final _ramp = _GainRamp();

/// How long before a song ends the next song's gain is prepared.
const gainLead = Duration(seconds: 1);

/// The gain to play with just before a song change: never more than either
/// song's. The new song starts no louder than it should, and is raised (if
/// at all) once it has begun, so its first moment can't blast.
double gainBeforeSwitch(double current, double next) => min(current, next);

/// Whether a song is about to end by itself.
bool endingSoon(Duration position, Duration? duration) => duration != null && duration > gainLead && duration - position <= gainLead;

/// Prepared for this song; `from` is the gain before that. Near a song's end
/// ([byHand] false), seeking back out of the last moments undoes it.
({String id, double from, bool byHand})? _held;

final volumeNormalizationProvider = Provider<void>((ref) {
  final on = ref.watch(settingsProvider.select((s) => s.normalizeVolume));
  final level = ref.watch(settingsProvider.select((s) => s.normalizeLevel));
  final gain = ref.watch(songGainProvider);
  // A new song's gain applies at once; one measured mid-song glides in.
  final position = ref.read(audioHandlerProvider).player.position;
  // The first seconds of a song still count as its start (its loudness may
  // be looked up a moment after it began).
  final instant = position < const Duration(seconds: 3);
  // In the middle of a song the volume only ever goes down (a song measured
  // late as quiet is raised from its next play, never with a sudden blast).
  double? capped(double? g) => g == null || instant ? g : min(g, _ramp.current);
  final handler = ref.read(audioHandlerProvider);
  late void Function(double) sendGain;

  /// Lowers the gain now if [next] needs less (see [gainBeforeSwitch]).
  Future<void> prepare(Track next, {bool byHand = false}) async {
    if (!on || !LoudnessService.measurable(next) || _held?.id == next.id) return;
    final service = ref.read(loudnessProvider);
    if (!await service.available) return;
    final saved = await service.saved(next);
    final g = saved != null ? songGain(saved, level) : unmeasuredGain(level);
    _held = (id: next.id, from: _ramp.current, byHand: byHand);
    _ramp.to(gainBeforeSwitch(_ramp.current, g), sendGain, instant: true);
  }

  /// In the last moments of a song, gets the next one ready; seeking back
  /// out of them puts the gain back.
  void follow() {
    handler.beforeSwitch = (next) => prepare(next, byHand: true);
    final sub = handler.player.positionStream.listen((pos) {
      final held = _held;
      if (held != null && handler.currentTrack?.id == held.id) {
        _held = null;
      } else if (endingSoon(pos, handler.player.duration)) {
        final next = handler.nextTrack;
        if (next != null && handler.player.playing) prepare(next);
      } else if (held != null && !held.byHand) {
        _held = null;
        _ramp.to(held.from, sendGain);
      }
    });
    ref.onDispose(sub.cancel);
  }
  if (Platform.isWindows || Platform.isLinux) {
    final eqOn = ref.watch(settingsProvider.select((s) => s.eqEnabled));
    final preset = ref.watch(settingsProvider.select((s) => s.eqPreset));
    final custom = ref.watch(settingsProvider.select((s) => s.eqCustom));
    final eq = eqOn ? eqGains(EqPreset.byName(preset), custom) : null;
    final values = windowsFilterValues(normalize: on, level: level, eq: eq, songGainDb: capped(gain));
    // The chain once, with no song's gain in it; after that only values change.
    if (JustAudioMediaKit.audioFilter.isEmpty) {
      JustAudioMediaKit.audioFilter = windowsFilterChain(windowsFilterValues(normalize: on, level: level, eq: eq, songGainDb: 0));
    }
    sendGain = (g) {
      final parts = windowsGain(g);
      JustAudioMediaKit.sendFilterCommand('volume@level', 'volume', '${parts.chain.toStringAsFixed(1)}dB');
      JustAudioMediaKit.setVolumeGain(parts.output);
    };
    for (final (target, option, value) in values) {
      if (target != 'volume@level') {
        JustAudioMediaKit.sendFilterCommand(target, option, value);
      } else if (gain == null) {
        sendGain(double.parse(value.replaceFirst('dB', '')));
      }
    }
    if (gain != null) _ramp.to(capped(gain)!, sendGain, instant: instant);
    follow();
    return;
  }
  if (!Platform.isAndroid) return;
  const channel = MethodChannel('ouo/normalize');
  final player = ref.read(audioHandlerProvider).player;
  int? session = player.androidAudioSessionId;
  void send(double g) {
    if (session == null) return;
    channel.invokeMethod('gain', {'sessionId': session, 'enabled': on, 'gainDb': g}).catchError((_) => false);
  }

  sendGain = send;
  _ramp.to(on ? capped(gain) ?? 0 : 0, send, instant: instant);
  follow();
  final sub = player.androidAudioSessionIdStream.listen((id) {
    session = id;
    send(_ramp.current);
  });
  ref.onDispose(sub.cancel);
});
