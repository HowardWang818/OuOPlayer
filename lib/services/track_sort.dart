import '../data/models/track.dart';

/// How a list of songs is shown. [custom] keeps the list's own order (a
/// playlist's arrangement, an album's track numbers…).
enum TrackSortKey {
  custom('預設順序'),
  title('歌名'),
  artist('歌手'),
  album('專輯'),
  added('加入日期'),
  duration('長度');

  const TrackSortKey(this.label);
  final String label;
}

class TrackSort {
  const TrackSort(this.key, {this.descending = false});
  final TrackSortKey key;
  final bool descending;

  static const custom = TrackSort(TrackSortKey.custom);

  /// Stored as 「key:asc」 or 「key:desc」.
  String encode() => '${key.name}:${descending ? 'desc' : 'asc'}';

  static TrackSort decode(String? s, {TrackSort fallback = custom}) {
    final parts = (s ?? '').split(':');
    final key = TrackSortKey.values.where((k) => k.name == parts.first).firstOrNull;
    return key == null ? fallback : TrackSort(key, descending: parts.length > 1 && parts[1] == 'desc');
  }

  /// Positions of [tracks] in display order. Ties keep the original order;
  /// songs with no length go last either way.
  List<int> order(List<Track> tracks) {
    final idx = List.generate(tracks.length, (i) => i);
    if (key == TrackSortKey.custom) return descending ? idx.reversed.toList() : idx;
    int cmp(int a, int b) {
      final x = tracks[a], y = tracks[b];
      final c = switch (key) {
        TrackSortKey.title => _text(x.title, y.title),
        TrackSortKey.artist => _text(x.artist, y.artist),
        TrackSortKey.album => _text(x.album, y.album),
        TrackSortKey.added => x.addedAt.compareTo(y.addedAt),
        TrackSortKey.duration => _nullsLast(x.durationMs, y.durationMs),
        TrackSortKey.custom => 0,
      };
      return c;
    }

    idx.sort((a, b) {
      var c = cmp(a, b);
      if (key == TrackSortKey.duration && (tracks[a].durationMs == null || tracks[b].durationMs == null)) {
        return c != 0 ? c : a.compareTo(b);
      }
      if (descending) c = -c;
      return c != 0 ? c : a.compareTo(b);
    });
    return idx;
  }

  static int _text(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());

  static int _nullsLast(int? a, int? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }
}

/// How the album and artist lists are shown.
enum GroupSortKey {
  name('名稱'),
  count('歌曲數'),
  recent('最近加入');

  const GroupSortKey(this.label);
  final String label;
}

class GroupSort {
  const GroupSort(this.key, {this.descending = false});
  final GroupSortKey key;
  final bool descending;

  String encode() => '${key.name}:${descending ? 'desc' : 'asc'}';

  static GroupSort decode(String? s) {
    final parts = (s ?? '').split(':');
    final key = GroupSortKey.values.where((k) => k.name == parts.first).firstOrNull;
    return key == null ? const GroupSort(GroupSortKey.name) : GroupSort(key, descending: parts.length > 1 && parts[1] == 'desc');
  }

  /// Sorts items by name, count or newest song. 「歌曲數」 and 「最近加入」
  /// put the biggest / newest first unless reversed.
  List<T> apply<T>(List<T> items, {required String Function(T) name, required int Function(T) count, required int Function(T) added}) {
    final list = [...items];
    int cmp(T a, T b) => switch (key) {
          GroupSortKey.name => name(a).toLowerCase().compareTo(name(b).toLowerCase()),
          GroupSortKey.count => count(b).compareTo(count(a)),
          GroupSortKey.recent => added(b).compareTo(added(a)),
        };
    list.sort((a, b) => descending ? cmp(b, a) : cmp(a, b));
    return list;
  }
}
