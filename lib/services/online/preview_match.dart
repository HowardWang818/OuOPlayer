import '../song_matcher.dart';
import 'itunes.dart';

/// 試聽: the iTunes song that is the same as [title] by [artist] (same
/// artist, close title) and has a 30-second preview, or null.
ITunesSong? previewMatch(String title, String artist, List<ITunesSong> results) {
  final want = SongKey(title, artist);
  final withPreview = results.where((s) => s.previewUrl != null);
  final (song, result) = SongMatcher.best(want, withPreview, (ITunesSong s) => SongKey(s.title, s.artist));
  return result.level == MatchLevel.no ? null : song;
}
