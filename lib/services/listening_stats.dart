import '../data/db/database.dart';
import '../data/models/track.dart';
import 'artists.dart';

enum StatsPeriod {
  week('本週'),
  month('本月'),
  year('今年'),
  all('全部');

  const StatsPeriod(this.label);
  final String label;

  /// [from, to) for this period around [now] (weeks start on Monday).
  (DateTime, DateTime) range(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    return switch (this) {
      StatsPeriod.week => (today.subtract(Duration(days: today.weekday - 1)), today.add(const Duration(days: 1))),
      StatsPeriod.month => (DateTime(now.year, now.month), DateTime(now.year, now.month + 1)),
      StatsPeriod.year => (DateTime(now.year), DateTime(now.year + 1)),
      StatsPeriod.all => (DateTime(2000), today.add(const Duration(days: 1))),
    };
  }
}

enum DayPart {
  morning('早上', 5, 12),
  afternoon('下午', 12, 18),
  evening('晚上', 18, 24),
  lateNight('深夜', 0, 5);

  const DayPart(this.label, this.fromHour, this.toHour);
  final String label;
  final int fromHour;
  final int toHour;

  static DayPart of(DateTime t) => values.firstWhere((p) => t.hour >= p.fromHour && t.hour < p.toHour);
}

class TrackCount {
  const TrackCount(this.track, this.plays, this.listened);
  final Track track;
  final int plays;
  final Duration listened;
}

class ArtistCount {
  const ArtistCount(this.name, this.plays, this.listened, this.art);
  final String name;
  final int plays;
  final Duration listened;
  final String? art;
}

/// Totals for one period. Music and podcasts are counted apart; previews
/// are never logged.
class ListeningStats {
  const ListeningStats({
    required this.music,
    required this.podcasts,
    required this.plays,
    required this.distinctSongs,
    required this.topTracks,
    required this.topArtists,
    required this.daily,
    required this.monthly,
    required this.dayParts,
    required this.hasEstimates,
  });

  final Duration music;
  final Duration podcasts;
  final int plays;
  final int distinctSongs;
  final List<TrackCount> topTracks;
  final List<ArtistCount> topArtists;

  /// Music time per day (date at midnight).
  final Map<DateTime, Duration> daily;

  /// Music time per month (1–12) — for the yearly review.
  final Map<int, Duration> monthly;
  final Map<DayPart, Duration> dayParts;

  /// Some entries came from the old history, with the song length assumed.
  final bool hasEstimates;

  bool get isEmpty => plays == 0 && podcasts == Duration.zero;

  int? get busiestMonth => monthly.isEmpty ? null : (monthly.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
  DayPart? get favouriteDayPart =>
      dayParts.isEmpty ? null : (dayParts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;

  /// Works the numbers out from the log; songs no longer in the library are
  /// left out of the top lists but still count towards the time.
  static ListeningStats compute(List<ListeningEntry> log, Map<String, Track> library, {int top = 10, int topArtists = 5}) {
    var music = Duration.zero, podcasts = Duration.zero;
    var plays = 0;
    var estimates = false;
    final perTrack = <String, (int, Duration)>{};
    final daily = <DateTime, Duration>{};
    final monthly = <int, Duration>{};
    final parts = <DayPart, Duration>{};
    for (final e in log) {
      if (e.source == TrackSource.preview) continue;
      if (e.source == TrackSource.podcast) {
        podcasts += e.listened;
        continue;
      }
      // Skipped within a few seconds: not a play.
      if (e.listened < const Duration(seconds: 5) && !e.estimated) continue;
      plays++;
      estimates |= e.estimated;
      music += e.listened;
      final (n, d) = perTrack[e.trackId] ?? (0, Duration.zero);
      perTrack[e.trackId] = (n + 1, d + e.listened);
      final day = DateTime(e.playedAt.year, e.playedAt.month, e.playedAt.day);
      daily[day] = (daily[day] ?? Duration.zero) + e.listened;
      monthly[e.playedAt.month] = (monthly[e.playedAt.month] ?? Duration.zero) + e.listened;
      final part = DayPart.of(e.playedAt);
      parts[part] = (parts[part] ?? Duration.zero) + e.listened;
    }
    int byPlays((int, Duration) a, (int, Duration) b) => a.$1 != b.$1 ? b.$1.compareTo(a.$1) : b.$2.compareTo(a.$2);
    final tracks = [
      for (final e in perTrack.entries)
        if (library[e.key] != null) TrackCount(library[e.key]!, e.value.$1, e.value.$2),
    ]..sort((a, b) => byPlays((a.plays, a.listened), (b.plays, b.listened)));
    // Plays count for the first artist credited (「YOASOBI, Ayase」→ YOASOBI).
    final dir = ArtistDirectory(library.values.map((t) => t.artist));
    final artists = <String, (int, Duration, String?)>{};
    final names = <String, String>{};
    for (final t in tracks) {
      if (t.track.artist == '網路串流') continue;
      for (final name in [if (dir.primary(t.track.artist) case final n?) n]) {
        final k = dir.keyOf(name);
        names[k] ??= name;
        final (n, d, art) = artists[k] ?? (0, Duration.zero, null);
        artists[k] = (n + t.plays, d + t.listened, art ?? t.track.art);
      }
    }
    final artistList = [for (final e in artists.entries) ArtistCount(names[e.key]!, e.value.$1, e.value.$2, e.value.$3)]
      ..sort((a, b) => byPlays((a.plays, a.listened), (b.plays, b.listened)));
    return ListeningStats(
      music: music,
      podcasts: podcasts,
      plays: plays,
      distinctSongs: perTrack.length,
      topTracks: tracks.take(top).toList(),
      topArtists: artistList.take(topArtists).toList(),
      daily: daily,
      monthly: monthly,
      dayParts: parts,
      hasEstimates: estimates,
    );
  }
}

/// 「32 小時 15 分」.
String formatListening(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60;
  if (h == 0) return '$m 分鐘';
  return m == 0 ? '$h 小時' : '$h 小時 $m 分';
}
