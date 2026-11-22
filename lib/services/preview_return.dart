import '../data/models/track.dart';

/// 試聽完回到原本的佇列 (1.22.0): the queue as it was when a preview took the
/// player. It is loaded again, paused, when the preview ends or is skipped.
/// What is done to the queue meanwhile (加入佇列, deleted or moved files,
/// edited songs, shuffle) is done to this.
///
/// Queue entries are told apart by identity: a song can be queued twice.
class BeforePreview {
  BeforePreview({
    required List<Track> tracks,
    required this.index,
    required this.position,
    required List<Track> unshuffled,
    required this.shuffled,
    required Set<Track> upNext,
    this.source,
    this.play,
  })  : tracks = List.of(tracks),
        unshuffled = List.of(unshuffled),
        upNext = Set.identity()..addAll(upNext);

  List<Track> tracks;
  int index;
  Duration position;
  List<Track> unshuffled;
  bool shuffled;
  final Set<Track> upNext;

  /// The list the queue was started from.
  String? source;

  /// The play that was going on at [index]: the same play goes on afterwards,
  /// so it isn't logged twice.
  ({int began, int heard})? play;

  Track? get current => index >= 0 && index < tracks.length ? tracks[index] : null;

  /// The hand-queued songs right after the current one, in order.
  List<Track> get waiting => [for (var i = index + 1; i < tracks.length && upNext.contains(tracks[i]); i++) tracks[i]];

  /// The pre-shuffle order, as indexes into [tracks].
  List<int> get original => [for (final t in unshuffled) tracks.indexWhere((x) => identical(x, t))];

  /// 加入佇列: after the current song and the songs queued before.
  void enqueue(List<Track> songs) {
    if (songs.isEmpty) return;
    final empty = tracks.isEmpty;
    tracks.insertAll(empty ? 0 : index + 1 + waiting.length, songs);
    if (shuffled) unshuffled.addAll(songs);
    if (empty) {
      // Nothing was playing: the first one is what comes back.
      index = 0;
      position = Duration.zero;
      upNext.addAll(songs.skip(1));
    } else {
      upNext.addAll(songs);
    }
  }

  /// Drops every entry of [ids]. The current one gone: the next that stays,
  /// from its start.
  void remove(Set<String> ids) {
    if (!tracks.any((t) => ids.contains(t.id))) return;
    final now = current;
    var at = tracks.take(index).where((t) => !ids.contains(t.id)).length;
    if (now != null && ids.contains(now.id)) {
      position = Duration.zero;
      play = null;
    }
    tracks = [for (final t in tracks) if (!ids.contains(t.id)) t];
    unshuffled = [for (final t in unshuffled) if (!ids.contains(t.id)) t];
    upNext.removeWhere((t) => ids.contains(t.id));
    if (at >= tracks.length) at = tracks.isEmpty ? 0 : tracks.length - 1;
    index = at;
    final next = current;
    if (next != null) upNext.remove(next);
  }

  /// Entries whose song changed (edited, or its file moved): [change] gives
  /// the new song, or null to leave it. True when any changed.
  bool replace(Track? Function(Track) change) {
    final to = Map<Track, Track>.identity();
    for (var i = 0; i < tracks.length; i++) {
      final old = tracks[i];
      final t = change(old);
      if (t == null) continue;
      to[old] = t;
      tracks[i] = t;
    }
    if (to.isEmpty) return false;
    unshuffled = [for (final t in unshuffled) to[t] ?? t];
    final queued = [for (final t in upNext) to[t] ?? t];
    upNext
      ..clear()
      ..addAll(queued);
    return true;
  }

  /// Shuffle turned on or off: [tail] is the new order after the current song.
  void rearrange(List<Track> tail, {required bool on}) {
    unshuffled = on ? List.of(tracks) : [];
    tracks = [...tracks.take(index + 1), ...tail];
    shuffled = on;
  }
}
