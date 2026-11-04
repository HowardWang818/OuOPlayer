import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:path/path.dart' as p;

import 'loudness.dart' show SongLoudness;
import 'ogg_tags.dart';

/// A song's loudness from its ReplayGain tags (track gain), when it has
/// them: 音量平衡 then needs no measuring. ReplayGain 2 aims at −18 LUFS,
/// Opus's R128_TRACK_GAIN at −23 LUFS (in 1/256 dB). A missing peak counts
/// as 0 dBFS, which only keeps a quiet song from being raised too far.
SongLoudness? replayGainOf(String path) {
  try {
    final ext = p.extension(path).toLowerCase();
    if (const {'.opus', '.ogg', '.oga'}.contains(ext)) {
      final tags = OggTags.read(File(path).readAsBytesSync());
      if (tags == null) return null;
      final r128 = int.tryParse(tags.first('R128_TRACK_GAIN')?.trim() ?? '');
      final rg = fromReplayGain(tags.first('REPLAYGAIN_TRACK_GAIN'), tags.first('REPLAYGAIN_TRACK_PEAK'));
      if (rg != null) return rg;
      return r128 == null ? null : _checked(-23 - r128 / 256, 0);
    }
    if (ext == '.m4a' || ext == '.mp4') {
      final f = _mp4Freeform(File(path));
      return fromReplayGain(f['replaygain_track_gain'], f['replaygain_track_peak']);
    }
    final m = readAllMetadata(File(path), getImage: false);
    if (m is VorbisMetadata) {
      return fromReplayGain(m.replayGainTrackGain.firstOrNull, m.replayGainTrackPeak.firstOrNull);
    }
    if (m is Mp3Metadata) {
      final tags = {for (final e in m.customMetadata.entries) e.key.toLowerCase(): e.value};
      return fromReplayGain(tags['replaygain_track_gain'], tags['replaygain_track_peak']);
    }
  } catch (_) {}
  return null;
}

/// "−6.48 dB" and "0.988" → loudness and peak.
SongLoudness? fromReplayGain(String? gain, String? peak) {
  // The number only: tags may carry a unit, spaces or NULs around it.
  double? number(String? s) => double.tryParse(_number.firstMatch(s ?? '')?[0] ?? '');
  final g = number(gain);
  if (g == null) return null;
  final pk = number(peak);
  return _checked(-18 - g, pk == null || pk <= 0 ? 0 : 20 * log(pk) / ln10);
}

final _number = RegExp(r'[-+]?\d+(?:\.\d+)?');

/// Nonsense values (a broken tag) don't count.
SongLoudness? _checked(double lufs, double peak) => lufs < -50 || lufs > 5 ? null : SongLoudness(lufs, min(peak, 6));

/// MP4's freeform tags (----:com.apple.iTunes:NAME), lower-cased names.
Map<String, String> _mp4Freeform(File f) {
  final raf = f.openSync();
  try {
    final size = raf.lengthSync();
    // moov may sit at the start or the end: find it among the top boxes.
    var o = 0;
    while (o + 8 <= size) {
      raf.setPositionSync(o);
      final h = raf.readSync(16);
      var len = ByteData.sublistView(h).getUint32(0);
      final type = ascii.decode(h.sublist(4, 8), allowInvalid: true);
      if (len == 1 && h.length >= 16) len = ByteData.sublistView(h).getUint64(8);
      if (len == 0) len = size - o;
      if (len < 8) break;
      if (type == 'moov') {
        if (len > 64 << 20) break;
        raf.setPositionSync(o);
        return _freeform(raf.readSync(len), 8, len);
      }
      o += len;
    }
  } finally {
    raf.closeSync();
  }
  return const {};
}

Map<String, String> _freeform(Uint8List b, int from, int to) {
  final out = <String, String>{};
  final d = ByteData.sublistView(b);
  void walk(int start, int end) {
    var o = start;
    while (o + 8 <= end) {
      final len = d.getUint32(o);
      if (len < 8 || o + len > end) return;
      final type = ascii.decode(b.sublist(o + 4, o + 8), allowInvalid: true);
      switch (type) {
        case 'udta' || 'ilst':
          walk(o + 8, o + len);
        case 'meta':
          walk(o + 12, o + len); // version and flags first
        case '----':
          String? name, value;
          var i = o + 8;
          while (i + 8 <= o + len) {
            final l = d.getUint32(i);
            if (l < 8 || i + l > o + len) break;
            final t = ascii.decode(b.sublist(i + 4, i + 8), allowInvalid: true);
            if (t == 'name') name = utf8.decode(b.sublist(i + 12, i + l), allowMalformed: true);
            if (t == 'data') value = utf8.decode(b.sublist(i + 16, i + l), allowMalformed: true);
            i += l;
          }
          if (name != null && value != null) out[name.toLowerCase()] = value;
      }
      o += len;
    }
  }

  walk(from, to);
  return out;
}
