/// One line of lyrics; [time] is null for plain (unsynced) lyrics.
class LyricLine {
  const LyricLine(this.time, this.text);
  final Duration? time;
  final String text;
}

/// Lyrics for a song and where they came from.
class Lyrics {
  const Lyrics(this.lines, {required this.source});

  final List<LyricLine> lines;

  /// 「歌曲檔案」, 「.lrc 檔」 or 「LRCLIB」.
  final String source;

  bool get synced => lines.isNotEmpty && lines.every((l) => l.time != null);
  bool get isEmpty => lines.every((l) => l.text.trim().isEmpty);

  /// The line being sung at [position] (-1 before the first one).
  int indexAt(Duration position) {
    if (!synced) return -1;
    var lo = 0, hi = lines.length - 1, found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].time! <= position) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return found;
  }

  /// Reads LRC text (「[mm:ss.xx] line」, several stamps per line allowed,
  /// [offset:±ms] honoured). Text without time stamps becomes plain lyrics.
  static Lyrics parse(String text, {required String source}) {
    final stamp = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
    final offsetTag = RegExp(r'^\[offset:\s*([+-]?\d+)\]', caseSensitive: false);
    final metaTag = RegExp(r'^\[[a-zA-Z]+:.*\]\s*$');
    var offset = 0;
    final timed = <LyricLine>[];
    final plain = <String>[];
    for (final raw in text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')) {
      final line = raw.trimRight();
      final o = offsetTag.firstMatch(line.trim());
      if (o != null) {
        offset = int.tryParse(o.group(1)!) ?? 0;
        continue;
      }
      final stamps = stamp.allMatches(line).toList();
      if (stamps.isEmpty || stamps.first.start != line.indexOf('[')) {
        if (!metaTag.hasMatch(line.trim())) plain.add(line);
        continue;
      }
      final words = line.substring(stamps.last.end).trim();
      for (final m in stamps) {
        final frac = m.group(3) ?? '0';
        final ms = int.parse(frac.padRight(3, '0').substring(0, 3));
        final t = Duration(minutes: int.parse(m.group(1)!), seconds: int.parse(m.group(2)!), milliseconds: ms);
        timed.add(LyricLine(t - Duration(milliseconds: offset), words));
      }
    }
    if (timed.isNotEmpty) {
      timed.sort((a, b) => a.time!.compareTo(b.time!));
      return Lyrics(timed, source: source);
    }
    while (plain.isNotEmpty && plain.first.trim().isEmpty) {
      plain.removeAt(0);
    }
    while (plain.isNotEmpty && plain.last.trim().isEmpty) {
      plain.removeLast();
    }
    return Lyrics([for (final l in plain) LyricLine(null, l)], source: source);
  }
}
