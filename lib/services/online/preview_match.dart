import '../song_matcher.dart';
import 'itunes.dart';

/// Version marks in titles: a preview must not switch between them (the
/// studio song shouldn't play its live take, and the other way round).
const _versionMarks = [
  'live', '現場', 'ライブ', 'first take', 'acoustic', 'アコースティック', 'remix', 'instrumental', 'inst.', 'off vocal', 'karaoke',
  'カラオケ', 'cover', 'カバー', '翻唱', 'sped up', 'slowed', 'nightcore', 'ver.', 'version', 'edit', 'demo', 'mix',
];

/// The version marks in [title] (lower-cased).
Set<String> versionMarks(String title) {
  final t = title.toLowerCase();
  return {for (final m in _versionMarks) if (t.contains(m)) m};
}

/// 試聽: the iTunes song that is the same as [title] by [artist] (same
/// artist, close title, the same version marks, length close when both are
/// known) and has a 30-second preview, or null.
ITunesSong? previewMatch(String title, String artist, List<ITunesSong> results, {int? durationMs}) {
  final want = SongKey(title, artist, durationMs: durationMs);
  final marks = versionMarks(title);
  final candidates = results.where((s) {
    if (s.previewUrl == null) return false;
    final theirs = versionMarks('${s.title} ${s.album}');
    return theirs.difference(marks).isEmpty && marks.difference(versionMarks(s.title)).isEmpty;
  });
  final (song, result) = SongMatcher.best(want, candidates, (ITunesSong s) => SongKey(s.title, s.artist, durationMs: s.durationMs));
  if (song == null || result.level == MatchLevel.no) return null;
  if (durationMs != null && song.durationMs != null && (durationMs - song.durationMs!).abs() > 20000) return null;
  return song;
}
