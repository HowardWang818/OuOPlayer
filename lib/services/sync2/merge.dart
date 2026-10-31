import 'dart:math';

import '../song_matcher.dart';

/// Playlist sync (v1.11.0): every synced playlist is kept as a [ListState]
/// built only from what the user did to it (added, removed, moved songs,
/// renamed or deleted it), each with when and on which device. Two devices'
/// states [join] the same way whatever order they meet in, so they always
/// end up equal; a song file vanishing from a device is never an action.

/// The key songs are recognised by across devices.
String songKey(String title, String artist) => '${foldText(title)}|${foldText(artist)}';

/// A change of one field: the latest (time, then device) wins.
class Stamped<T> {
  const Stamped(this.value, this.at, this.device);
  final T value;
  final int at;
  final String device;

  bool beats(Stamped<Object?>? other) => other == null || at > other.at || (at == other.at && device.compareTo(other.device) > 0);
  List<Object?> toJson() => [value, at, device];
  static Stamped<T>? fromJson<T>(Object? j) => j is List && j.length == 3 ? Stamped<T>(j[0] as T, (j[1] as num).toInt(), j[2] as String) : null;
}

Stamped<T>? _latest<T>(Stamped<T>? a, Stamped<T>? b) => a == null ? b : (b != null && b.beats(a) ? b : a);

/// One entry of a playlist (the same song twice is two entries).
class ListItem {
  ListItem({required this.song, required this.order, required this.addedAt, this.removedAt});

  /// {t, a, al, ms}: title, artist, album, length.
  final Map<String, Object?> song;

  /// Where it sits (sort key) and when that was decided.
  final Stamped<double> order;
  final int addedAt;

  /// Set once removed: an entry never comes back (adding again is a new entry).
  final int? removedAt;

  bool get visible => removedAt == null;
  String get key => songKey('${song['t']}', '${song['a']}');

  ListItem copyWith({Stamped<double>? order, int? removedAt}) =>
      ListItem(song: song, order: order ?? this.order, addedAt: addedAt, removedAt: removedAt ?? this.removedAt);

  static ListItem join(ListItem a, ListItem b) => ListItem(
        song: a.song,
        order: _latest(a.order, b.order)!,
        addedAt: min(a.addedAt, b.addedAt),
        removedAt: a.removedAt == null ? b.removedAt : (b.removedAt == null ? a.removedAt : min(a.removedAt!, b.removedAt!)),
      );

  Map<String, Object?> toJson() => {'s': song, 'o': order.toJson(), 'a': addedAt, if (removedAt != null) 'r': removedAt};
  static ListItem fromJson(Map j) => ListItem(
        song: (j['s'] as Map).cast<String, Object?>(),
        order: Stamped<double>(((j['o'] as List)[0] as num).toDouble(), ((j['o'] as List)[1] as num).toInt(), (j['o'] as List)[2] as String),
        addedAt: (j['a'] as num).toInt(),
        removedAt: (j['r'] as num?)?.toInt(),
      );
}

/// A synced playlist: its name, whether it was deleted, its entries.
class ListState {
  ListState({this.name, this.deleted, Map<String, ListItem>? items}) : items = items ?? {};
  final Stamped<String>? name;
  final Stamped<bool>? deleted;
  final Map<String, ListItem> items;

  bool get isDeleted => deleted?.value == true;

  /// The entries shown, in order.
  List<MapEntry<String, ListItem>> get shown {
    final list = items.entries.where((e) => e.value.visible).toList()
      ..sort((a, b) {
        final c = a.value.order.value.compareTo(b.value.order.value);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    return list;
  }

  static ListState join(ListState a, ListState b) {
    final items = Map.of(a.items);
    for (final e in b.items.entries) {
      final mine = items[e.key];
      items[e.key] = mine == null ? e.value : ListItem.join(mine, e.value);
    }
    return ListState(name: _latest(a.name, b.name), deleted: _latest(a.deleted, b.deleted), items: items);
  }

  Map<String, Object?> toJson() => {
        if (name != null) 'n': name!.toJson(),
        if (deleted != null) 'd': deleted!.toJson(),
        'i': {for (final e in items.entries) e.key: e.value.toJson()},
      };

  static ListState fromJson(Map j) => ListState(
        name: Stamped.fromJson<String>(j['n']),
        deleted: Stamped.fromJson<bool>(j['d']),
        items: {for (final e in ((j['i'] as Map?) ?? const {}).entries) '${e.key}': ListItem.fromJson(e.value as Map)},
      );

  /// Removed entries are dropped after [keep] (the other device has long seen them).
  ListState pruned(int now, {Duration keep = const Duration(days: 90)}) => ListState(
        name: name,
        deleted: deleted,
        items: {for (final e in items.entries) if (e.value.removedAt == null || now - e.value.removedAt! < keep.inMilliseconds) e.key: e.value},
      );
}

/// A row of the playlist on this device: its entry id (null for a row the
/// user just added) and the song.
class LocalRow {
  const LocalRow(this.itemId, this.song);
  final String? itemId;
  final Map<String, Object?> song;
}

/// What the user did on this device, worked out from the playlist as it is
/// now ([rows], after a user action) against [state]: rows without an entry
/// id are added, entries gone from the rows are removed, and entries that
/// changed place get a new sort key (as few as possible: the longest run
/// still in order keeps its keys). [newId] names new entries.
({ListState state, List<String> ids}) recordRows(ListState state, List<LocalRow> rows, int now, String device, String Function() newId) {
  final items = Map.of(state.items);
  final ids = [for (final r in rows) r.itemId != null && items.containsKey(r.itemId) && items[r.itemId]!.visible ? r.itemId! : newId()];
  final present = ids.toSet();
  for (final e in state.items.entries) {
    if (e.value.visible && !present.contains(e.key)) items[e.key] = e.value.copyWith(removedAt: now);
  }
  // Entries that keep their key: the longest run whose keys are still increasing.
  final known = [for (var i = 0; i < ids.length; i++) if (state.items[ids[i]]?.visible == true) i];
  final keep = _longestIncreasing([for (final i in known) state.items[ids[i]]!.order.value]).map((k) => known[k]).toSet();
  // Everything else gets a key between its kept neighbours.
  var i = 0;
  while (i < ids.length) {
    if (keep.contains(i)) {
      i++;
      continue;
    }
    var j = i;
    while (j < ids.length && !keep.contains(j)) {
      j++;
    }
    final lo = i == 0 ? null : items[ids[i - 1]]!.order.value;
    final hi = j >= ids.length ? null : items[ids[j]]!.order.value;
    final n = j - i;
    for (var k = 0; k < n; k++) {
      final double v = lo == null && hi == null
          ? (k + 1).toDouble()
          : lo == null
              ? hi! - (n - k)
              : hi == null
                  ? lo + k + 1
                  : lo + (hi - lo) * (k + 1) / (n + 1);
      final order = Stamped<double>(v, now, device);
      final existing = items[ids[i + k]];
      items[ids[i + k]] = existing != null && existing.visible
          ? existing.copyWith(order: order)
          : ListItem(song: rows[i + k].song, order: order, addedAt: now);
    }
    i = j;
  }
  return (state: ListState(name: state.name, deleted: state.deleted, items: items), ids: ids);
}

/// Indexes of a longest strictly increasing subsequence of [xs].
List<int> _longestIncreasing(List<double> xs) {
  final tails = <int>[];
  final prev = List<int>.filled(xs.length, -1);
  for (var i = 0; i < xs.length; i++) {
    var lo = 0, hi = tails.length;
    while (lo < hi) {
      final m = (lo + hi) >> 1;
      if (xs[tails[m]] < xs[i]) {
        lo = m + 1;
      } else {
        hi = m;
      }
    }
    if (lo > 0) prev[i] = tails[lo - 1];
    if (lo == tails.length) {
      tails.add(i);
    } else {
      tails[lo] = i;
    }
  }
  final out = <int>[];
  for (var k = tails.isEmpty ? -1 : tails.last; k >= 0; k = prev[k]) {
    out.add(k);
  }
  return out.reversed.toList();
}
