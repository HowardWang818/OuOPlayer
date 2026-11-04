import 'dart:convert';
import 'dart:typed_data';

/// Tags (Vorbis comments) of Ogg Opus and Ogg Vorbis files (.opus, .ogg),
/// read and written here: the tag library reads them but can't write them.
///
/// Writing rebuilds only the header pages (the comment packet, and Vorbis's
/// setup packet after it); every audio page keeps its bytes, with only its
/// page number and checksum updated when the header takes more or fewer
/// pages than before.
class OggTags {
  OggTags._(this.codec, this.vendor, this.comments, this._extra);

  final OggCodec codec;
  final String vendor;

  /// Every comment as it is in the file (`NAME=value`), in order.
  final List<String> comments;

  /// Opus: binary data after the comments, kept as it is.
  final Uint8List _extra;

  /// The values of [name] (case doesn't matter).
  List<String> values(String name) {
    final key = '${name.toUpperCase()}=';
    return [for (final c in comments) if (c.length >= key.length && c.substring(0, key.length).toUpperCase() == key) c.substring(key.length)];
  }

  String? first(String name) => values(name).firstOrNull;

  /// Reads the tags of an Ogg Opus / Vorbis file; null for anything else.
  static OggTags? read(Uint8List bytes) {
    try {
      final h = _Headers.parse(bytes);
      return h == null ? null : _parseComments(h.codec, h.packets[1]);
    } on FormatException {
      return null;
    }
  }

  /// [bytes] with title, artist and album set (and the cover, when given);
  /// other comments stay. Throws [FormatException] for a file it can't
  /// rewrite safely.
  static Uint8List write(Uint8List bytes, {required String title, required String artist, required String album, Uint8List? cover, String coverMime = 'image/jpeg'}) {
    final h = _Headers.parse(bytes);
    if (h == null) throw const FormatException('不是 Ogg Opus 或 Vorbis 檔案');
    final tags = _parseComments(h.codec, h.packets[1]);
    const replaced = {'TITLE', 'ARTIST', 'ALBUM'};
    const pictures = {'METADATA_BLOCK_PICTURE', 'COVERART', 'COVERARTMIME'};
    final kept = [
      for (final c in tags.comments)
        if (!replaced.contains(_name(c)) && !(cover != null && pictures.contains(_name(c)))) c,
    ];
    final next = [
      'TITLE=$title',
      if (artist.isNotEmpty) 'ARTIST=$artist',
      if (album.isNotEmpty) 'ALBUM=$album',
      ...kept,
      if (cover != null) 'METADATA_BLOCK_PICTURE=${base64.encode(_picture(cover, coverMime))}',
    ];
    final packet = _commentPacket(h.codec, tags.vendor, next, tags._extra);
    return h.rebuild([h.packets[0], packet, ...h.packets.skip(2)]);
  }

  /// [bytes] with exactly [comments] as its tags.
  static Uint8List withComments(Uint8List bytes, List<String> comments) {
    final h = _Headers.parse(bytes);
    if (h == null) throw const FormatException('不是 Ogg Opus 或 Vorbis 檔案');
    final tags = _parseComments(h.codec, h.packets[1]);
    return h.rebuild([h.packets[0], _commentPacket(h.codec, tags.vendor, comments, tags._extra), ...h.packets.skip(2)]);
  }

  static String _name(String comment) {
    final i = comment.indexOf('=');
    return (i < 0 ? comment : comment.substring(0, i)).toUpperCase();
  }

  static OggTags _parseComments(OggCodec codec, Uint8List p) {
    final r = _Reader(p);
    if (codec == OggCodec.opus) {
      if (ascii.decode(r.take(8), allowInvalid: true) != 'OpusTags') throw const FormatException('沒有 OpusTags');
    } else {
      if (r.byte() != 3 || ascii.decode(r.take(6), allowInvalid: true) != 'vorbis') throw const FormatException('沒有 Vorbis 註解');
    }
    final vendor = utf8.decode(r.take(r.u32()), allowMalformed: true);
    final n = r.u32();
    final comments = [for (var i = 0; i < n; i++) utf8.decode(r.take(r.u32()), allowMalformed: true)];
    // Opus may carry binary data after the comments; Vorbis ends with its framing bit.
    final extra = codec == OggCodec.opus ? r.rest() : Uint8List(0);
    return OggTags._(codec, vendor, comments, extra);
  }

  static Uint8List _commentPacket(OggCodec codec, String vendor, List<String> comments, Uint8List extra) {
    final b = BytesBuilder();
    void u32(int v) => b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
    void text(String s) {
      final e = utf8.encode(s);
      u32(e.length);
      b.add(e);
    }

    if (codec == OggCodec.opus) {
      b.add(ascii.encode('OpusTags'));
    } else {
      b.addByte(3);
      b.add(ascii.encode('vorbis'));
    }
    text(vendor);
    u32(comments.length);
    comments.forEach(text);
    if (codec == OggCodec.opus) {
      b.add(extra);
    } else {
      b.addByte(1); // framing bit
    }
    return b.toBytes();
  }

  /// A FLAC picture block (front cover), as Opus and Vorbis files carry it.
  static Uint8List _picture(Uint8List data, String mime) {
    final b = BytesBuilder();
    void u32(int v) => b.add((ByteData(4)..setUint32(0, v)).buffer.asUint8List());
    u32(3); // front cover
    final m = ascii.encode(mime);
    u32(m.length);
    b.add(m);
    u32(0); // no description
    for (var i = 0; i < 4; i++) {
      u32(0); // width, height, depth, colours: unknown
    }
    u32(data.length);
    b.add(data);
    return b.toBytes();
  }
}

enum OggCodec { opus, vorbis }

class _Page {
  _Page(this.start, this.flags, this.granule, this.serial, this.sequence, this.segments, this.dataStart, this.end);
  final int start;
  final int flags;
  final int granule;
  final int serial;
  final int sequence;
  final List<int> segments;
  final int dataStart;
  final int end;

  static _Page? at(Uint8List b, int o) {
    if (o + 27 > b.length || b[o] != 0x4F || b[o + 1] != 0x67 || b[o + 2] != 0x67 || b[o + 3] != 0x53 || b[o + 4] != 0) return null;
    final d = ByteData.sublistView(b);
    final n = b[o + 26];
    if (o + 27 + n > b.length) return null;
    final segments = b.sublist(o + 27, o + 27 + n);
    final dataStart = o + 27 + n;
    final end = dataStart + segments.fold<int>(0, (a, s) => a + s);
    if (end > b.length) return null;
    return _Page(o, b[o + 5], d.getInt64(o + 6, Endian.little), d.getUint32(o + 14, Endian.little), d.getUint32(o + 18, Endian.little), segments,
        dataStart, end);
  }
}

/// The header packets of the file's first stream, and where its audio starts.
class _Headers {
  _Headers(this.bytes, this.codec, this.packets, this.serial, this.headerPages, this.audioStart);
  final Uint8List bytes;
  final OggCodec codec;
  final List<Uint8List> packets;
  final int serial;
  final int headerPages;
  final int audioStart;

  static _Headers? parse(Uint8List b) {
    final first = _Page.at(b, 0);
    if (first == null || first.flags & 2 == 0) return null;
    final packets = <Uint8List>[];
    final current = BytesBuilder();
    OggCodec? codec;
    var wanted = 2;
    var o = 0;
    var pages = 0;
    while (packets.length < wanted) {
      final page = _Page.at(b, o);
      if (page == null) throw const FormatException('Ogg 頁面不完整');
      if (page.serial != first.serial) throw const FormatException('檔案裡有多個串流');
      if (page.sequence != pages) throw const FormatException('Ogg 頁面順序不對');
      var at = page.dataStart;
      for (final s in page.segments) {
        current.add(b.sublist(at, at + s));
        at += s;
        if (s < 255) {
          packets.add(current.takeBytes());
          if (packets.length == 1) {
            final p = packets.first;
            if (p.length >= 8 && ascii.decode(p.sublist(0, 8), allowInvalid: true) == 'OpusHead') {
              codec = OggCodec.opus;
            } else if (p.length >= 7 && p[0] == 1 && ascii.decode(p.sublist(1, 7), allowInvalid: true) == 'vorbis') {
              codec = OggCodec.vorbis;
              wanted = 3;
            } else {
              return null;
            }
          }
        }
      }
      o = page.end;
      pages++;
      // The headers must end where a page ends; audio starts on a new page.
      if (packets.length >= wanted && current.length > 0) throw const FormatException('標頭和聲音在同一頁');
      if (packets.length > wanted) throw const FormatException('標頭和聲音在同一頁');
    }
    return _Headers(b, codec!, packets, first.serial, pages, o);
  }

  /// The file with [newPackets] as its headers: the first packet keeps a page
  /// of its own (as the formats require), the others follow on new pages.
  Uint8List rebuild(List<Uint8List> newPackets) {
    final out = BytesBuilder();
    var seq = 0;
    void page(List<int> segments, List<Uint8List> parts, {required int flags, required int granule}) {
      final header = ByteData(27);
      header.setUint32(0, 0x5367674F, Endian.little); // OggS
      header.setUint8(4, 0);
      header.setUint8(5, flags);
      header.setInt64(6, granule, Endian.little);
      header.setUint32(14, serial, Endian.little);
      header.setUint32(18, seq++, Endian.little);
      header.setUint8(26, segments.length);
      final bytes = BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(segments);
      parts.forEach(bytes.add);
      out.add(_withCrc(bytes.toBytes()));
    }

    // Packet 0: its own page, as it was (BOS).
    page(_lacing(newPackets[0].length), [newPackets[0]], flags: 2, granule: 0);
    // The rest of the headers, packed into as few pages as fit.
    final rest = newPackets.skip(1).toList();
    final segs = [for (final p in rest) ..._lacing(p.length)];
    final joined = BytesBuilder();
    rest.forEach(joined.add);
    final data = joined.toBytes();
    var pos = 0;
    var continued = false;
    for (var i = 0; i < segs.length; i += 255) {
      final chunk = segs.sublist(i, i + 255 > segs.length ? segs.length : i + 255);
      final size = chunk.fold<int>(0, (a, s) => a + s);
      // A page where a packet ends carries granule 0, else "no packet ends here" (-1).
      final ends = chunk.any((s) => s < 255);
      page(chunk, [data.sublist(pos, pos + size)], flags: continued ? 1 : 0, granule: ends ? 0 : -1);
      pos += size;
      continued = chunk.last == 255;
    }
    final shift = seq - headerPages;
    // The audio: as it was; this stream's page numbers move by [shift].
    var o = audioStart;
    while (o < bytes.length) {
      final p = _Page.at(bytes, o);
      if (p == null) {
        out.add(bytes.sublist(o)); // trailing bytes that aren't a page
        break;
      }
      final raw = bytes.sublist(p.start, p.end);
      if (shift == 0 || p.serial != serial) {
        out.add(raw);
      } else {
        ByteData.sublistView(raw).setUint32(18, p.sequence + shift, Endian.little);
        out.add(_withCrc(raw));
      }
      o = p.end;
    }
    return out.toBytes();
  }
}

/// Segment sizes for a packet of [length] bytes.
List<int> _lacing(int length) => [...List.filled(length ~/ 255, 255), length % 255];

/// [page] with its checksum filled in.
Uint8List _withCrc(Uint8List page) {
  final d = ByteData.sublistView(page)..setUint32(22, 0, Endian.little);
  d.setUint32(22, oggCrc(page), Endian.little);
  return page;
}

final _crcTable = List<int>.generate(256, (i) {
  var r = i << 24;
  for (var k = 0; k < 8; k++) {
    r = r & 0x80000000 != 0 ? ((r << 1) ^ 0x04C11DB7) & 0xFFFFFFFF : (r << 1) & 0xFFFFFFFF;
  }
  return r;
});

/// Ogg's page checksum (CRC-32, polynomial 0x04C11DB7, not reflected).
int oggCrc(Uint8List data) {
  var crc = 0;
  for (final b in data) {
    crc = ((crc << 8) & 0xFFFFFFFF) ^ _crcTable[((crc >> 24) ^ b) & 0xFF];
  }
  return crc;
}

class _Reader {
  _Reader(this.b);
  final Uint8List b;
  var o = 0;

  int byte() {
    if (o >= b.length) throw const FormatException('註解不完整');
    return b[o++];
  }

  int u32() {
    if (o + 4 > b.length) throw const FormatException('註解不完整');
    final v = ByteData.sublistView(b).getUint32(o, Endian.little);
    o += 4;
    return v;
  }

  Uint8List take(int n) {
    if (n < 0 || o + n > b.length) throw const FormatException('註解不完整');
    final r = b.sublist(o, o + n);
    o += n;
    return r;
  }

  Uint8List rest() => b.sublist(o);
}
