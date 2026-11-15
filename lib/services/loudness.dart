import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/db/database.dart';
import '../data/models/track.dart';
import '../providers/providers.dart' show NormalizeLevel;
import 'replay_gain.dart';
import 'replay_gain_writer.dart' show canWriteReplayGain;
import 'tag_editor.dart' show writeReplayGainQuietly;

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
/// into the limiter at −1 dBFS, which rounds them off); raising mid-song
/// glides in slowly, so it is never a sudden blast.
double songGain(SongLoudness s, NormalizeLevel level) {
  final wanted = targetLufs(level) - s.lufs;
  final room = -1 - s.peak + 6;
  return min(wanted, max(0.0, room)).clamp(-24.0, 9.0);
}

/// A song not measured yet plays this much quieter (per strength): most music
/// is mastered well above the target; a song that turns out quiet is raised
/// slowly once measured (1.20.14; before, only from its next play).
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

  /// Songs whose tags were read where nothing could measure: tried again
  /// once something can (Windows: ffmpeg comes with the first download).
  final _tagsOnly = <String>{};
  bool _couldMeasure = false;

  /// Songs that couldn't be measured this run: not tried again.
  final _failed = <String>{};

  /// Songs that mustn't be rewritten now (the playing and the next one).
  bool Function(String trackId) busy = (_) => false;

  /// Writes a measurement into the file (tests replace it).
  Future<bool> Function(String path, SongLoudness l) writeFile = writeReplayGainQuietly;

  StreamSubscription<void>? _watch;
  Timer? _settle;

  /// From the start (1.20.14): the library's songs are measured in the
  /// background as soon as they come in (scan, download, sync), whether or
  /// not 音量平衡 is on, instead of only after something plays.
  void start({Duration first = const Duration(seconds: 10), Duration settle = const Duration(seconds: 5)}) {
    if (_watch != null) return;
    _settle = Timer(first, () => unawaited(scanLibrary()));
    _watch = _db.changes.listen((_) {
      _settle?.cancel();
      _settle = Timer(settle, () => unawaited(scanLibrary()));
    });
  }

  void stop() {
    _watch?.cancel();
    _watch = null;
    _settle?.cancel();
  }

  static bool measurable(Track t) =>
      (t.source == TrackSource.local || t.source == TrackSource.download) && !t.isRemote && t.uri.isNotEmpty && t.fileExists;

  /// Windows: ffmpeg is there (it comes with the first download).
  Future<String?> _ffmpeg() async {
    if (!Platform.isWindows) return null;
    try {
      final f = File(p.join((await getApplicationSupportDirectory()).path, 'bin', 'ffmpeg.exe'));
      return f.existsSync() ? f.path : null;
    } catch (_) {
      return null;
    }
  }

  /// Whether songs can be measured on this device (ReplayGain tags are read
  /// everywhere).
  Future<bool> get available async => Platform.isAndroid || await _ffmpeg() != null;

  Future<SongLoudness?> saved(Track t) => _db.loudness(t.id);

  /// The song's loudness: saved, or measured now ([urgent]: before the others waiting).
  Future<SongLoudness?> get(Track t, {bool urgent = false}) async {
    final known = await saved(t);
    if (known != null || !measurable(t)) return known;
    // ReplayGain tags: no measuring needed.
    final tagged = await _tagged(t);
    if (tagged != null) return tagged;
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

  /// The library's songs not measured yet, in the background.
  Future<void> scanLibrary() async {
    unawaited(writeWaiting());
    final can = await available;
    if (can && !_couldMeasure) _tagsOnly.clear();
    _couldMeasure = can;
    final known = await _db.loudnessIds();
    for (final t in await _db.tracks()) {
      if (measurable(t) && !known.contains(t.id) && !_pending.containsKey(t.id) && !_failed.contains(t.id) && !_tagsOnly.contains(t.id)) {
        _pending[t.id] = (t, Completer<SongLoudness?>());
      }
    }
    unawaited(_work());
  }

  // ---------- written into the files (1.20.14) ----------

  static const _toWrite = 'loudness_to_write';
  static const _oldWritten = 'loudness_write_v1';

  Future<Set<String>> _waiting() async {
    try {
      return {...(jsonDecode((await _db.allSettings())[_toWrite] ?? '[]') as List).cast<String>()};
    } catch (_) {
      return {};
    }
  }

  static bool _writable(Track t) => t.source == TrackSource.download && canWriteReplayGain(t.uri);

  bool _writing = false;

  /// Downloaded songs' measurements go into their files (once for the
  /// songs measured before 1.20.14); the playing and next song wait.
  Future<void> writeWaiting() async {
    if (_writing) return;
    _writing = true;
    try {
      final s = await _db.allSettings();
      var ids = await _waiting();
      if (s[_oldWritten] != '1') {
        final known = await _db.loudnessIds();
        ids = {...ids, for (final t in await _db.tracks()) if (_writable(t) && known.contains(t.id)) t.id};
        await _db.setSetting(_toWrite, jsonEncode(ids.toList()));
        await _db.setSetting(_oldWritten, '1');
      }
      if (ids.isEmpty) return;
      final done = <String>{};
      for (final id in ids) {
        if (busy(id)) continue;
        final t = await _db.track(id);
        final l = await _db.loudness(id);
        if (t == null || l == null || !_writable(t)) {
          done.add(id);
          continue;
        }
        if (!File(t.uri).existsSync()) continue; // being moved or renamed: next time
        // A file that already says it (its own tags) needs nothing.
        final has = await Isolate.run(() => replayGainOf(t.uri));
        if (has == null || (has.lufs - l.lufs).abs() >= 0.01) {
          try {
            await writeFile(t.uri, l);
          } catch (_) {}
        }
        done.add(id);
      }
      if (done.isNotEmpty) await _db.setSetting(_toWrite, jsonEncode((await _waiting()).difference(done).toList()));
    } finally {
      _writing = false;
    }
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
          r = await _tagged(t);
          if (r == null) {
            r = await _measure(t.uri);
            if (r != null) {
              await _db.setLoudness(t.id, r.lufs, r.peak);
              if (_writable(t)) {
                await _db.setSetting(_toWrite, jsonEncode({...await _waiting(), t.id}.toList()));
              }
            } else if (await available) {
              _failed.add(t.id);
            } else {
              _tagsOnly.add(t.id);
            }
          }
        } catch (_) {
          _failed.add(t.id);
        }
        if (!done.isCompleted) done.complete(r);
        // Background songs leave the phone breathing room.
        await Future.delayed(const Duration(milliseconds: 300));
      }
    } finally {
      _running = false;
    }
    unawaited(writeWaiting());
  }

  /// The song's ReplayGain tags (kept like a measurement).
  Future<SongLoudness?> _tagged(Track t) async {
    final r = await Isolate.run(() => replayGainOf(t.uri));
    if (r != null) await _db.setLoudness(t.id, r.lufs, r.peak);
    return r;
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
