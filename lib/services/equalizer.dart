import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';

/// The five bands the presets and the 自訂 sliders use (Hz). Android
/// devices have their own bands; each gets the gain at its centre frequency.
const eqFrequencies = [60, 230, 910, 3600, 14000];
const eqMaxDb = 12.0;

enum EqPreset {
  flat('標準', [0, 0, 0, 0, 0]),
  bass('重低音', [6, 4, 0, 0, 0]),
  vocal('人聲', [-2, -1, 3, 4, 1]),
  pop('流行', [-1, 2, 4, 2, -1]),
  rock('搖滾', [4, 2, -1, 2, 4]),
  classical('古典', [3, 2, -1, 2, 3]),
  custom('自訂', null);

  const EqPreset(this.label, this.gains);
  final String label;
  final List<double>? gains;

  static EqPreset byName(String? name) => values.where((p) => p.name == name).firstOrNull ?? flat;
}

/// The five band gains for a preset (自訂 uses the user's own values).
List<double> eqGains(EqPreset preset, List<double> custom) =>
    preset.gains ?? (custom.length == eqFrequencies.length ? custom : EqPreset.flat.gains!);

/// Gain at any frequency, interpolated between the five bands on a log scale.
double eqGainAt(double hz, List<double> gains) {
  if (hz <= eqFrequencies.first) return gains.first;
  if (hz >= eqFrequencies.last) return gains.last;
  for (var i = 0; i < eqFrequencies.length - 1; i++) {
    final lo = eqFrequencies[i].toDouble(), hi = eqFrequencies[i + 1].toDouble();
    if (hz <= hi) {
      final t = (log(hz) - log(lo)) / (log(hi) - log(lo));
      return gains[i] + (gains[i + 1] - gains[i]) * t;
    }
  }
  return gains.last;
}

/// ffmpeg peaking filters for mpv (Windows), one per band that isn't flat.
String windowsEqFilter(List<double> gains) => [
      for (var i = 0; i < eqFrequencies.length; i++)
        if (gains[i] != 0) 'equalizer=f=${eqFrequencies[i]}:t=o:w=2:g=${gains[i].toStringAsFixed(1)}',
    ].join(',');

/// Keeps the Android equalizer in step with the settings. (Windows: the
/// filter is combined with volume normalization in volumeNormalizationProvider.)
final equalizerProvider = Provider<void>((ref) {
  if (!Platform.isAndroid) return;
  final s = ref.watch(settingsProvider);
  final eq = ref.read(audioHandlerProvider).equalizer;
  if (eq == null) return;
  final gains = eqGains(EqPreset.byName(s.eqPreset), s.eqCustom);
  () async {
    try {
      await eq.setEnabled(s.eqEnabled);
      if (!s.eqEnabled) return;
      // Ready once the player has loaded something.
      final params = await eq.parameters;
      for (final band in params.bands) {
        var hz = band.centerFrequency;
        if (hz > 100000) hz /= 1000; // some devices report millihertz
        await band.setGain(eqGainAt(hz, gains).clamp(params.minDecibels, params.maxDecibels));
      }
    } catch (_) {}
  }();
});
