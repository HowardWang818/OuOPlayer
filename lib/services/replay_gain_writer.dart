import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'loudness.dart' show SongLoudness;
import 'ogg_tags.dart';

/// Writes a song's measured loudness into its file as ReplayGain 2 track
/// tags (1.20.14), so it is never measured again (another device, a new
/// install, other players). Read back by [replayGainOf].
///
/// The tag library rewrites MP3, MP4 and FLAC tags from scratch and drops
/// ReplayGain, so these are written here, keeping everything else as it is.

const _gainName = 'replaygain_track_gain';
const _peakName = 'replaygain_track_peak';

/// The tag values for [s]: the gain to −18 LUFS, the peak as a ratio.
({String gain, String peak}) replayGainText(SongLoudness s) =>
    (gain: '${(-18 - s.lufs).toStringAsFixed(2)} dB', peak: pow(10, s.peak / 20).toStringAsFixed(6));

/// Formats that can take ReplayGain tags here.
const replayGainExtensions = {'.mp3', '.m4a', '.mp4', '.flac', '.opus', '.ogg', '.oga'};

bool canWriteReplayGain(String path) => replayGainExtensions.contains(p.extension(path).toLowerCase());

/// [bytes] (a file named [path]) with ReplayGain track tags for [s]; other
/// ReplayGain track tags are replaced. Null when the file can't take them
/// safely.
Uint8List? withReplayGain(String path, Uint8List bytes, SongLoudness s) {
  final t = replayGainText(s);
  try {
    return switch (p.extension(path).toLowerCase()) {
      '.opus' || '.ogg' || '.oga' => _ogg(bytes, t.gain, t.peak),
      '.mp3' => _id3(bytes, t.gain, t.peak),
      '.m4a' || '.mp4' => _mp4(bytes, t.gain, t.peak),
      '.flac' => _flac(bytes, t.gain, t.peak),
      _ => null,
    };
  } catch (_) {
    return null;
  }
}

bool _isOurs(String name) {
  final n = name.trim().toLowerCase();
  return n == _gainName || n == _peakName;
}

String _commentName(String c) {
  final i = c.indexOf('=');
  return i < 0 ? c : c.substring(0, i);
}

// ---------- Ogg ----------

Uint8List? _ogg(Uint8List bytes, String gain, String peak) {
  final tags = OggTags.read(bytes);
  if (tags == null) return null;
  return OggTags.withComments(bytes, [
    for (final c in tags.comments)
      if (!_isOurs(_commentName(c))) c,
    'REPLAYGAIN_TRACK_GAIN=$gain',
    'REPLAYGAIN_TRACK_PEAK=$peak',
  ]);
}

// ---------- FLAC ----------

Uint8List? _flac(Uint8List b, String gain, String peak) {
  if (b.length < 8 || ascii.decode(b.sublist(0, 4), allowInvalid: true) != 'fLaC') return null;
  final blocks = <(int, Uint8List)>[];
  var o = 4;
  while (true) {
    if (o + 4 > b.length) return null;
    final last = b[o] & 0x80 != 0;
    final type = b[o] & 0x7f;
    final len = (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
    if (o + 4 + len > b.length) return null;
    blocks.add((type, Uint8List.sublistView(b, o + 4, o + 4 + len)));
    o += 4 + len;
    if (last) break;
  }
  final audio = Uint8List.sublistView(b, o);
  final ours = ['REPLAYGAIN_TRACK_GAIN=$gain', 'REPLAYGAIN_TRACK_PEAK=$peak'];
  Uint8List comments(String vendor, List<String> list) {
    final out = BytesBuilder();
    void u32(int v) => out.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
    final v = utf8.encode(vendor);
    u32(v.length);
    out.add(v);
    u32(list.length);
    for (final c in list) {
      final e = utf8.encode(c);
      u32(e.length);
      out.add(e);
    }
    return out.toBytes();
  }

  final i = blocks.indexWhere((x) => x.$1 == 4);
  if (i >= 0) {
    final d = ByteData.sublistView(blocks[i].$2);
    final body = blocks[i].$2;
    var q = 0;
    final vl = d.getUint32(q, Endian.little);
    q += 4;
    final vendor = utf8.decode(body.sublist(q, q + vl), allowMalformed: true);
    q += vl;
    final n = d.getUint32(q, Endian.little);
    q += 4;
    final list = <String>[];
    for (var k = 0; k < n; k++) {
      final l = d.getUint32(q, Endian.little);
      q += 4;
      list.add(utf8.decode(body.sublist(q, q + l), allowMalformed: true));
      q += l;
    }
    blocks[i] = (4, comments(vendor, [for (final c in list) if (!_isOurs(_commentName(c))) c, ...ours]));
  } else {
    if (blocks.isEmpty) return null;
    blocks.insert(1, (4, comments('OuOPlayer', ours)));
  }
  final out = BytesBuilder()..add(ascii.encode('fLaC'));
  for (var k = 0; k < blocks.length; k++) {
    final (type, body) = blocks[k];
    if (body.length >= 1 << 24) return null;
    out.add([(k == blocks.length - 1 ? 0x80 : 0) | type, body.length >> 16 & 0xff, body.length >> 8 & 0xff, body.length & 0xff]);
    out.add(body);
  }
  out.add(audio);
  return out.toBytes();
}

// ---------- MP3 (ID3v2 TXXX) ----------

int _syncsafe(Uint8List b, int o) => (b[o] & 0x7f) << 21 | (b[o + 1] & 0x7f) << 14 | (b[o + 2] & 0x7f) << 7 | (b[o + 3] & 0x7f);

List<int> _toSyncsafe(int v) => [v >> 21 & 0x7f, v >> 14 & 0x7f, v >> 7 & 0x7f, v & 0x7f];

List<int> _u32(int v) => [v >> 24 & 0xff, v >> 16 & 0xff, v >> 8 & 0xff, v & 0xff];

/// A TXXX frame's description.
String _txxxName(Uint8List body) {
  if (body.isEmpty) return '';
  final enc = body[0];
  if (enc == 1 || enc == 2) {
    var end = 1;
    while (end + 1 < body.length && !(body[end] == 0 && body[end + 1] == 0)) {
      end += 2;
    }
    var s = body.sublist(1, min(end, body.length));
    var little = enc == 1; // UTF-16 without a BOM: little-endian is the common case
    if (s.length >= 2 && s[0] == 0xff && s[1] == 0xfe) {
      little = true;
      s = s.sublist(2);
    } else if (s.length >= 2 && s[0] == 0xfe && s[1] == 0xff) {
      little = false;
      s = s.sublist(2);
    }
    if (enc == 2) little = false;
    final units = [for (var k = 0; k + 1 < s.length; k += 2) little ? s[k] | s[k + 1] << 8 : s[k] << 8 | s[k + 1]];
    return String.fromCharCodes(units);
  }
  final end = body.indexOf(0, 1);
  final raw = body.sublist(1, end < 0 ? body.length : end);
  return enc == 3 ? utf8.decode(raw, allowMalformed: true) : latin1.decode(raw);
}

Uint8List? _id3(Uint8List b, String gain, String peak) {
  var version = 4;
  var flags = 0;
  final frames = BytesBuilder();
  var audioStart = 0;
  if (b.length >= 10 && b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) {
    version = b[3];
    flags = b[5];
    // Unsynchronised tags, extended headers and footers: left alone.
    if ((version != 3 && version != 4) || flags & 0xd0 != 0) return null;
    final size = _syncsafe(b, 6);
    final end = 10 + size;
    if (end > b.length) return null;
    var o = 10;
    while (o + 10 <= end) {
      if (b[o] == 0) break; // padding
      final id = ascii.decode(b.sublist(o, o + 4), allowInvalid: true);
      final len = version == 4 ? _syncsafe(b, o + 4) : ByteData.sublistView(b).getUint32(o + 4);
      if (o + 10 + len > end) return null;
      final keep = !(id == 'TXXX' && _isOurs(_txxxName(Uint8List.sublistView(b, o + 10, o + 10 + len))));
      if (keep) frames.add(Uint8List.sublistView(b, o, o + 10 + len));
      o += 10 + len;
    }
    audioStart = end;
  }
  List<int> txxx(String name, String value) {
    final body = [3, ...utf8.encode(name), 0, ...utf8.encode(value)];
    return [...ascii.encode('TXXX'), ...(version == 4 ? _toSyncsafe(body.length) : _u32(body.length)), 0, 0, ...body];
  }

  frames
    ..add(txxx(_gainName.toUpperCase(), gain))
    ..add(txxx(_peakName.toUpperCase(), peak));
  final body = frames.toBytes();
  if (body.length >= 1 << 28) return null;
  return (BytesBuilder()
        ..add([0x49, 0x44, 0x33, version, 0, flags, ..._toSyncsafe(body.length)])
        ..add(body)
        ..add(Uint8List.sublistView(b, audioStart)))
      .toBytes();
}

// ---------- MP4 (iTunes freeform atoms) ----------

String _type(Uint8List b, int o) => ascii.decode(b.sublist(o + 4, o + 8), allowInvalid: true);

List<int> _box(String type, List<int> body) => [..._u32(body.length + 8), ...ascii.encode(type), ...body];

/// The child box [type] of the box body [start, end): (offset, size).
(int, int)? _child(Uint8List b, int start, int end, String type) {
  final d = ByteData.sublistView(b);
  var o = start;
  while (o + 8 <= end) {
    final len = d.getUint32(o);
    if (len < 8 || o + len > end) return null;
    if (_type(b, o) == type) return (o, len);
    o += len;
  }
  return null;
}

Uint8List? _mp4(Uint8List b, String gain, String peak) {
  final d = ByteData.sublistView(b);
  // moov among the top boxes.
  (int, int)? moov;
  var o = 0;
  while (o + 8 <= b.length) {
    final len = d.getUint32(o);
    if (len < 8 || o + len > b.length) return null; // 64-bit or open-ended boxes: left alone
    if (_type(b, o) == 'moov') {
      moov = (o, len);
      break;
    }
    o += len;
  }
  if (moov == null) return null;
  final (mo, ml) = moov;

  List<int> freeform(String name, String value) => _box('----', [
        ..._box('mean', [0, 0, 0, 0, ...ascii.encode('com.apple.iTunes')]),
        ..._box('name', [0, 0, 0, 0, ...utf8.encode(name)]),
        ..._box('data', [0, 0, 0, 1, 0, 0, 0, 0, ...utf8.encode(value)]),
      ]);
  final ours = [...freeform(_gainName, gain), ...freeform(_peakName, peak)];

  // What changes: a range [from, to) replaced by [insert]; the boxes around it grow.
  late int from, to;
  late List<int> insert;
  final grown = <int>[mo];
  final udta = _child(b, mo + 8, mo + ml, 'udta');
  if (udta == null) {
    from = to = mo + ml;
    insert = _box('udta', _metaBox(ours));
  } else {
    grown.add(udta.$1);
    final meta = _child(b, udta.$1 + 8, udta.$1 + udta.$2, 'meta');
    if (meta == null) {
      from = to = udta.$1 + udta.$2;
      insert = _metaBox(ours);
    } else {
      grown.add(meta.$1);
      if (d.getUint32(meta.$1 + 8) != 0) return null; // not the usual full box
      final ilst = _child(b, meta.$1 + 12, meta.$1 + meta.$2, 'ilst');
      if (ilst == null) {
        from = to = meta.$1 + meta.$2;
        insert = _box('ilst', ours);
      } else {
        from = ilst.$1;
        to = ilst.$1 + ilst.$2;
        final kept = <int>[];
        var i = ilst.$1 + 8;
        while (i + 8 <= to) {
          final len = d.getUint32(i);
          if (len < 8 || i + len > to) return null;
          final name = _type(b, i) == '----' ? _freeformName(b, i, len) : null;
          if (name == null || !_isOurs(name)) kept.addAll(b.sublist(i, i + len));
          i += len;
        }
        insert = _box('ilst', [...kept, ...ours]);
      }
    }
  }
  final delta = insert.length - (to - from);
  if (ml + delta >= 1 << 32) return null;
  final out = Uint8List(b.length + delta);
  out.setRange(0, from, b);
  out.setRange(from, from + insert.length, insert);
  out.setRange(from + insert.length, out.length, b, to);
  final od = ByteData.sublistView(out);
  for (final g in grown) {
    od.setUint32(g, od.getUint32(g) + delta);
  }
  // The audio after moov moved: its chunk offsets follow.
  if (delta != 0 && !_shiftChunks(out, mo, ml + delta, mo, delta)) return null;
  return out;
}

List<int> _metaBox(List<int> ilstBody) => _box('meta', [
      0, 0, 0, 0,
      ..._box('hdlr', [0, 0, 0, 0, 0, 0, 0, 0, ...ascii.encode('mdirappl'), 0, 0, 0, 0, 0, 0, 0, 0, 0]),
      ..._box('ilst', ilstBody),
    ]);

String? _freeformName(Uint8List b, int o, int len) {
  final d = ByteData.sublistView(b);
  var i = o + 8;
  while (i + 8 <= o + len) {
    final l = d.getUint32(i);
    if (l < 12 || i + l > o + len) return null;
    if (_type(b, i) == 'name') return utf8.decode(b.sublist(i + 12, i + l), allowMalformed: true);
    i += l;
  }
  return null;
}

/// Adds [delta] to every chunk offset at or after [after] in the stco / co64
/// boxes inside the moov at [mo]. False when one would overflow.
bool _shiftChunks(Uint8List b, int mo, int ml, int after, int delta) {
  final d = ByteData.sublistView(b);
  bool walk(int start, int end) {
    var o = start;
    while (o + 8 <= end) {
      final len = d.getUint32(o);
      if (len < 8 || o + len > end) return true;
      switch (_type(b, o)) {
        case 'trak' || 'mdia' || 'minf' || 'stbl':
          if (!walk(o + 8, o + len)) return false;
        case 'stco':
          final n = d.getUint32(o + 12);
          for (var k = 0; k < n && o + 16 + k * 4 + 4 <= o + len; k++) {
            final at = o + 16 + k * 4;
            final v = d.getUint32(at);
            if (v >= after) {
              if (v + delta >= 1 << 32 || v + delta < 0) return false;
              d.setUint32(at, v + delta);
            }
          }
        case 'co64':
          final n = d.getUint32(o + 12);
          for (var k = 0; k < n && o + 16 + k * 8 + 8 <= o + len; k++) {
            final at = o + 16 + k * 8;
            final v = d.getUint64(at);
            if (v >= after) d.setUint64(at, v + delta);
          }
      }
      o += len;
    }
    return true;
  }

  return walk(mo + 8, mo + ml);
}
