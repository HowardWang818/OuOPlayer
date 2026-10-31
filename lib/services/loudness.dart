import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/db/database.dart';
import '../data/models/track.dart';
import '../providers/providers.dart' show NormalizeLevel;

/// A song's integrated loudness (LUFS, EBU R128) and sample peak (dBFS).
class SongLoudness {
  const SongLoudness(this.lufs, this.peak);
  final double lufs;
  final double peak;
}

/// The loudness each 音量平衡 strength aims every song at (Spotify's normal
/// is −14 LUFS).
double targetLufs(NormalizeLevel level) => switch (level) {
      NormalizeLevel.quiet => -20,
      NormalizeLevel.normal => -14,
      NormalizeLevel.loud => -10,
    };

/// The one fixed gain (dB) for a whole song: what brings it to the target. A
/// quiet song is raised at most 9 dB and only as far as its peaks allow (6 dB
/// into the limiter at −1 dBFS, which rounds them off); raising only ever
/// happens at the start of a song, so it is never a sudden blast.
double songGain(SongLoudness s, NormalizeLevel level) {
  final wanted = targetLufs(level) - s.lufs;
  final room = -1 - s.peak + 6;
  return min(wanted, max(0.0, room)).clamp(-24.0, 9.0);
}

/// A song not measured yet plays this much quieter (per strength): most music
/// is mastered well above the target, and a song that turns out quiet is only
/// raised from its next play (never in the middle of it).
double unmeasuredGain(NormalizeLevel level) => switch (level) {
      NormalizeLevel.quiet => -12,
      NormalizeLevel.normal => -6,
      NormalizeLevel.loud => -2,
    };

/// The last of 「I: … LUFS」 and 「Peak: … dBFS」 in ffmpeg's ebur128 summary.
SongLoudness? parseEbur128(String log) {
  final i = RegExp(r'I:\s+(-?\d+(?:\.\d+)?) LUFS').allMatches(log).lastOrNull;
  final peak = RegExp(r'Peak:\s+(-?\d+(?:\.\d+)?|-inf) dBFS').allMatches(log).lastOrNull;
  if (i == null || peak == null) return null;
  final lufs = double.parse(i[1]!);
  if (lufs <= -70) return null; // silence
  return SongLoudness(lufs, peak[1] == '-inf' ? -90 : double.parse(peak[1]!));
}

/// Measures songs once (phone: Android's decoder, NormalizerPlugin.kt;
/// Windows: the ffmpeg fetched for downloads) and keeps the result in the
/// library. One song at a time: the playing / next song first, then the
/// rest of the library in the background.
class LoudnessService {
  LoudnessService(this._db);
  final AppDatabase _db;
  static const _channel = MethodChannel('ouo/normalize');

  final _pending = <String, (Track, Completer<SongLoudness?>)>{};
  bool _running = false;
  bool _scanned = false;

  static bool measurable(Track t) =>
      (t.source == TrackSource.local || t.source == TrackSource.download) && !t.isRemote && t.uri.isNotEmpty && t.fileExists;

  /// Windows: ffmpeg is there (it comes with the first download).
  Future<String?> _ffmpeg() async {
    if (!Platform.isWindows) return null;
    final f = File(p.join((await getApplicationSupportDirectory()).path, 'bin', 'ffmpeg.exe'));
    return f.existsSync() ? f.path : null;
  }

  /// Whether songs can be measured on this device.
  Future<bool> get available async => Platform.isAndroid || await _ffmpeg() != null;

  Future<SongLoudness?> saved(Track t) => _db.loudness(t.id);

  /// The song's loudness: saved, or measured now ([urgent]: before the others waiting).
  Future<SongLoudness?> get(Track t, {bool urgent = false}) async {
    final known = await saved(t);
    if (known != null || !measurable(t)) return known;
    final waiting = _pending.remove(t.id);
    final done = waiting?.$2 ?? Completer<SongLoudness?>();
    final entry = (t, done);
    if (urgent) {
      final rest = Map.of(_pending);
      _pending
        ..clear()
        ..[t.id] = entry
        ..addAll(rest);
    } else {
      _pending[t.id] = entry;
    }
    unawaited(_work());
    return done.future;
  }

  /// Once per run: the library's songs not measured yet, in the background.
  Future<void> scanLibrary() async {
    if (_scanned || !await available) return;
    _scanned = true;
    final known = await _db.loudnessIds();
    for (final t in await _db.tracks()) {
      if (measurable(t) && !known.contains(t.id) && !_pending.containsKey(t.id)) {
        _pending[t.id] = (t, Completer<SongLoudness?>());
      }
    }
    unawaited(_work());
  }

  Future<void> _work() async {
    if (_running) return;
    _running = true;
    try {
      while (_pending.isNotEmpty) {
        final id = _pending.keys.first;
        final (t, done) = _pending.remove(id)!;
        SongLoudness? r;
        try {
          r = await _measure(t.uri);
          if (r != null) await _db.setLoudness(t.id, r.lufs, r.peak);
        } catch (_) {}
        if (!done.isCompleted) done.complete(r);
        // Background songs leave the phone breathing room.
        await Future.delayed(const Duration(milliseconds: 300));
      }
    } finally {
      _running = false;
    }
  }

  Future<SongLoudness?> _measure(String path) async {
    if (Platform.isAndroid) {
      final m = await _channel.invokeMapMethod<String, Object?>('measure', {'path': path});
      if (m == null) return null;
      return SongLoudness((m['lufs'] as num).toDouble(), (m['peak'] as num).toDouble());
    }
    final ffmpeg = await _ffmpeg();
    if (ffmpeg == null) return null;
    final r = await Process.run(ffmpeg, ['-hide_banner', '-nostats', '-i', path, '-vn', '-af', 'ebur128=peak=sample', '-f', 'null', '-'],
        stdoutEncoding: const SystemEncoding(), stderrEncoding: const SystemEncoding());
    return parseEbur128('${r.stderr}');
  }
}
