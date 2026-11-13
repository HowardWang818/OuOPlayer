import '../song_matcher.dart';
import 'itunes.dart';

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
