import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../data/db/database.dart';
import '../data/models/track.dart';
import 'audio_handler.dart';
import 'sync2/merge.dart' show songKey;
import 'track_sort.dart';

/// 1.24.0: a playlist's (or the liked songs') own queue: its order, the song
/// it is at, where in it (this device only), and whether it is shuffled.
/// Songs are told by their names ([entryKeys]), so the same queue means the
/// same on another device.
class ListQueue {
  ListQueue({required this.order, this.index = 0, this.positionMs = 0, this.shuffled = false, this.at = 0, this.device = ''});

  /// [entryKeys] of the songs in play order.
  final List<String> order;
  final int index;
  final int positionMs;
  final bool shuffled;

  /// When the last action on it (a song, a pause, a shuffle) was, and where.
  final int at;
  final String device;

  String? get current => index >= 0 && index < order.length ? order[index] : null;

  ListQueue copyWith({List<String>? order, int? index, int? positionMs, bool? shuffled, int? at, String? device}) => ListQueue(
        order: order ?? this.order,
        index: index ?? this.index,
        positionMs: positionMs ?? this.positionMs,
        shuffled: shuffled ?? this.shuffled,
        at: at ?? this.at,
        device: device ?? this.device,
      );

  Map<String, Object?> toJson() => {'o': order, 'i': index, 'p': positionMs, 's': shuffled, 'at': at, 'd': device};

  /// What another device gets: no second (nobody is left half way).
  Map<String, Object?> toSync() => {'o': order, 'i': index, 's': shuffled, 'at': at, 'd': device};

  static ListQueue fromJson(Map j) => ListQueue(
        order: [for (final k in (j['o'] as List? ?? const [])) '$k'],
        index: (j['i'] as num?)?.toInt() ?? 0,
        positionMs: (j['p'] as num?)?.toInt() ?? 0,
        shuffled: j['s'] == true,
        at: (j['at'] as num?)?.toInt() ?? 0,
        device: '${j['d'] ?? ''}',
      );

  /// Newer: a later action, or the same moment on a later device id.
  bool newerThan(ListQueue? o) => o == null || at > o.at || (at == o.at && device.compareTo(o.device) > 0);

  bool sameAs(ListQueue o) => jsonEncode(toJson()) == jsonEncode(o.toJson());
}

/// Each song's key in a list: its names, and #2, #3… for the same song again.
List<String> entryKeys(List<Track> tracks) {
  final seen = <String, int>{};
  return [
    for (final t in tracks)
      () {
        final k = songKey(t.title, t.artist);
        final n = seen[k] = (seen[k] ?? 0) + 1;
        return n == 1 ? k : '$k#$n';
      }(),
  ];
}

/// [q] for the list as it is now ([keys], in the list's own order): songs no
/// longer in it are taken out, new ones go into what is still to come
/// (somewhere random when shuffled, else at the end). The song it was at
/// stays, or the next one that is still there.
ListQueue reconcile(ListQueue q, List<String> keys, {Random? random}) {
  final now = keys.toSet();
  final had = q.order.toSet();
  final kept = [for (final k in q.order) if (now.contains(k)) k];
  var index = 0;
  final cur = q.current;
  if (cur != null) {
    if (now.contains(cur)) {
      index = kept.indexOf(cur);
    } else {
      final later = q.order.skip(q.index + 1).where(now.contains).firstOrNull;
      index = later == null ? max(0, kept.length - 1) : kept.indexOf(later);
    }
  }
  final added = [for (final k in keys) if (!had.contains(k)) k];
  final r = random ?? Random();
  final order = [...kept];
  for (final k in added) {
    if (q.shuffled && order.length > index + 1) {
      order.insert(index + 1 + r.nextInt(order.length - index), k);
    } else {
      order.add(k);
    }
  }
  if (order.isEmpty) index = 0;
  return q.copyWith(order: order, index: min(index, max(0, order.length - 1)));
}

/// A new round of a list: shuffled from a random song, or in its own order.
List<String> roundOf(List<String> keys, bool shuffled, Random random) => shuffled ? ([...keys]..shuffle(random)) : [...keys];

/// The playlists' and the liked songs' own queues, kept in the library
/// (table list_queues) and played by [handler].
class ListQueues {
  /// [attach]: follow [handler] (false: only the stored queues, for pages
  /// shown in tests on a stand-in player).
  ListQueues(this.db, this.handler, {required this.deviceId, int Function()? clock, Random? random, bool attach = true})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _random = random ?? Random() {
    _attached = attach;
    if (attach) {
      handler
        ..onSave = _onSave
        ..onNewQueue = _onNewQueue
        ..roundFor = _roundFor
        ..onListShuffle = _onListShuffle;
      _subs = [
        handler.player.currentIndexStream.distinct().listen((_) => _capture(action: true)),
        handler.player.playingStream.distinct().skip(1).listen((on) => _capture(action: !on)),
        db.changes.listen((_) => _soonReconcile()),
      ];
    } else {
      _subs = [];
    }
    ready = _load();
  }

  late final bool _attached;

  final AppDatabase db;
  final OuoAudioHandler handler;
  final Future<String> Function() deviceId;
  final int Function() _clock;
  final Random _random;
  late final List<StreamSubscription<Object?>> _subs;
  late final Future<void> ready;
  final _queues = <String, ListQueue>{};
  final _changes = StreamController<String>.broadcast();
  String _me = '';
  bool _disposed = false;

  /// A list's queue changed by an action here ([String] its key): worth
  /// sending to the other devices.
  void Function(String key)? onAction;

  /// Any change (the shuffle buttons follow it).
  Stream<String> get changes => _changes.stream;

  static const favorites = 'favorites';
  static String keyFor(int? playlistId) => playlistId == null ? favorites : 'playlist:$playlistId';
  static bool isList(String? key) => key == favorites || (key?.startsWith('playlist:') ?? false);
  static int? playlistOf(String key) => key.startsWith('playlist:') ? int.tryParse(key.substring(9)) : null;

  Future<void> _load() async {
    try {
      _me = await deviceId();
      for (final r in await db.db.query('list_queues')) {
        _queues['${r['key']}'] = ListQueue.fromJson(jsonDecode('${r['state']}') as Map);
      }
    } catch (_) {}
  }

  ListQueue? operator [](String key) => _queues[key];
  Map<String, ListQueue> get all => Map.unmodifiable(_queues);
  bool shuffledOf(String key) => _queues[key]?.shuffled ?? false;

  /// This list is what plays (or is loaded) now.
  bool isCurrent(String key) => handler.queueSource == key && handler.queueTracks.isNotEmpty;

  Future<void> _put(String key, ListQueue q) async {
    final before = _queues[key];
    if (before != null && before.sameAs(q)) return;
    _queues[key] = q;
    _changes.add(key);
    try {
      await db.db.insert('list_queues', {'key': key, 'state': jsonEncode(q.toJson())}, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (_) {}
  }

  /// The list's playable songs, in its own order (as its page sorts it).
  Future<List<Track>> tracksOf(String key) async {
    final id = playlistOf(key);
    final List<Track> all;
    final String? sort;
    if (id != null) {
      all = await db.playlistTracks(id);
      sort = (await db.db.query('playlists', columns: ['sort'], where: 'id = ?', whereArgs: [id])).firstOrNull?['sort'] as String?;
    } else {
      all = await db.favorites();
      sort = (await db.allSettings())['sort_favorites'];
    }
    final shown = [for (final i in TrackSort.decode(sort).order(all)) all[i]];
    return [for (final t in shown) if (t.fileExists) t];
  }

  /// The list's queue for its songs now ([shown]: as the page has them).
  Future<(ListQueue, Map<String, Track>)> _queueFor(String key, List<Track> shown) async {
    await ready;
    final playable = [for (final t in shown) if (t.fileExists) t];
    final keys = entryKeys(playable);
    final byKey = {for (var i = 0; i < keys.length; i++) keys[i]: playable[i]};
    final old = _queues[key];
    final q = old == null || old.order.isEmpty
        ? ListQueue(order: roundOf(keys, old?.shuffled ?? false, _random), shuffled: old?.shuffled ?? false, at: old?.at ?? 0, device: old?.device ?? '')
        : reconcile(old, keys, random: _random);
    return (q, byKey);
  }

  Future<void> _load2(String key, ListQueue q, Map<String, Track> byKey, {bool play = true, int? index, Duration? position}) async {
    final keys = [for (final k in q.order) if (byKey.containsKey(k)) k];
    if (keys.isEmpty) return;
    final at = index ?? max(0, keys.indexOf(q.current ?? ''));
    await handler.loadList([for (final k in keys) byKey[k]!],
        index: at, position: position ?? Duration(milliseconds: q.positionMs), shuffled: q.shuffled, source: key, play: play);
  }

  /// The big play button: this list playing → pause / go on; another list or
  /// nothing → this list's own queue, at its song and second.
  Future<void> playButton(String key, List<Track> shown) async {
    if (isCurrent(key)) {
      handler.player.playing ? await handler.pause() : await handler.play();
      return;
    }
    final (q, byKey) = await _queueFor(key, shown);
    await _load2(key, q, byKey);
  }

  /// A song of the list tapped: from there, the queue's order as it is.
  Future<void> playFrom(String key, List<Track> shown, Track song) async {
    final (q, byKey) = await _queueFor(key, shown);
    final keys = [for (final k in q.order) if (byKey.containsKey(k)) k];
    final mine = byKey.entries.where((e) => identical(e.value, song) || e.value.id == song.id).map((e) => e.key).toList();
    var at = keys.indexWhere(mine.contains);
    if (at < 0) at = 0;
    if (isCurrent(key) && handler.queueTracks.length == keys.length) {
      await handler.skipToQueueItem(at);
      return;
    }
    await _load2(key, q, byKey, index: at, position: Duration.zero);
  }

  /// The list's shuffle button: on → the whole list shuffled again, from its
  /// new first song at once; off → only off (the queue stays as it is).
  Future<void> toggleShuffle(String key, List<Track> shown) async {
    final (q, byKey) = await _queueFor(key, shown);
    if (q.shuffled) {
      await _put(key, q.copyWith(shuffled: false, at: _clock(), device: _me));
      if (isCurrent(key)) handler.markShuffled(false);
      onAction?.call(key);
      return;
    }
    final keys = entryKeys([for (final t in shown) if (t.fileExists) t]);
    final fresh = q.copyWith(order: roundOf(keys, true, _random), index: 0, positionMs: 0, shuffled: true, at: _clock(), device: _me);
    await _put(key, fresh);
    await _load2(key, fresh, byKey, index: 0, position: Duration.zero);
    onAction?.call(key);
  }

  /// The player bar's shuffle button while a list plays.
  Future<bool> _onListShuffle(bool on) async {
    final key = handler.queueSource;
    if (!isList(key) || _disposed) return false;
    if (on == shuffledOf(key!)) return true;
    await toggleShuffle(key, await tracksOf(key));
    return true;
  }

  /// The list's next round when the queue ends (繼續加歌曲).
  Future<List<Track>?> _roundFor(String? source) async {
    if (!isList(source)) return null;
    final key = source!;
    final shown = await tracksOf(key);
    final keys = entryKeys(shown);
    final byKey = {for (var i = 0; i < keys.length; i++) keys[i]: shown[i]};
    final shuffled = shuffledOf(key);
    final order = roundOf(keys, shuffled, _random);
    await _put(key, ListQueue(order: order, shuffled: shuffled, at: _clock(), device: _me));
    onAction?.call(key);
    return [for (final k in order) byKey[k]!];
  }

  /// What the player has now, for its list. [action]: a song changed or it
  /// paused (the other devices follow the last action).
  /// Taking another device's queue: what the player had isn't kept over it.
  bool _adopting = false;

  void _capture({required bool action}) {
    if (_disposed || _adopting) return;
    final key = handler.queueSource;
    if (!isList(key) || handler.previewing || handler.loadingQueue) return;
    final list = handler.queueTracks;
    if (list.isEmpty) return;
    final old = _queues[key!];
    final q = ListQueue(
      order: entryKeys(list),
      index: handler.player.currentIndex ?? 0,
      positionMs: handler.player.position.inMilliseconds,
      shuffled: old?.shuffled ?? handler.shuffled,
      at: action ? _clock() : old?.at ?? _clock(),
      device: action ? _me : old?.device ?? _me,
    );
    if (old != null && jsonEncode(old.toSync()) == jsonEncode(q.toSync()) && old.positionMs == q.positionMs) return;
    final moved = old == null || jsonEncode(old.toSync()..remove('at')..remove('d')) != jsonEncode(q.toSync()..remove('at')..remove('d'));
    unawaited(_put(key, moved || !action ? q : q.copyWith(at: old.at, device: old.device)));
    if (action && moved) onAction?.call(key);
  }

  void _onSave() => _capture(action: false);

  /// The list that played until now keeps where it was.
  void _onNewQueue({required bool pickUp}) => _capture(action: false);

  Timer? _reconcileSoon;
  void _soonReconcile() {
    _reconcileSoon?.cancel();
    _reconcileSoon = Timer(const Duration(milliseconds: 500), () => unawaited(reconcileAll()));
  }

  /// Songs added to or taken out of a list: its queue follows at once (also
  /// the one playing: what is still to come changes, the song goes on).
  Future<void> reconcileAll() async {
    await ready;
    for (final key in [..._queues.keys]) {
      if (_disposed) return;
      final q = _queues[key]!;
      if (q.order.isEmpty) continue;
      final id = playlistOf(key);
      if (id != null && (await db.db.query('playlists', columns: ['id'], where: 'id = ?', whereArgs: [id])).isEmpty) {
        _queues.remove(key);
        await db.db.delete('list_queues', where: 'key = ?', whereArgs: [key]);
        continue;
      }
      final shown = await tracksOf(key);
      final keys = entryKeys(shown);
      final current = isCurrent(key);
      final base = current ? q.copyWith(order: entryKeys(handler.queueTracks), index: handler.player.currentIndex ?? q.index) : q;
      final next = reconcile(base, keys, random: _random);
      if (jsonEncode(next.order) == jsonEncode(base.order)) continue;
      await _put(key, next);
      if (current) {
        final byKey = {for (var i = 0; i < keys.length; i++) keys[i]: shown[i]};
        // The song playing was taken out: it ends, and the next one still in
        // the list comes after it.
        final gone = base.current != null && !keys.contains(base.current);
        await handler.replaceUpcoming([for (final k in next.order.skip(gone ? next.index : next.index + 1)) if (byKey[k] != null) byKey[k]!]);
      }
    }
  }

  /// Another device's queue of [key], newer than this one's: this device
  /// goes on from the song after the one it was at there (nobody is left half
  /// way). Playing this list here: the song playing ends first.
  Future<void> adopt(String key, ListQueue theirs) async {
    await ready;
    final shown = await tracksOf(key);
    final keys = entryKeys(shown);
    final byKey = {for (var i = 0; i < keys.length; i++) keys[i]: shown[i]};
    var order = [for (final k in theirs.order) if (byKey.containsKey(k)) k];
    // Songs only here go at the end (or randomly in what is to come).
    var next = theirs.index + 1;
    final skipped = theirs.order.take(next).where(byKey.containsKey).length;
    var q = reconcile(ListQueue(order: order, index: skipped, shuffled: theirs.shuffled), keys, random: _random);
    order = q.order;
    next = skipped;
    if (next >= order.length) {
      order = roundOf(keys, theirs.shuffled, _random);
      next = 0;
    }
    q = ListQueue(order: order, index: next, shuffled: theirs.shuffled, at: theirs.at, device: theirs.device);
    if (isCurrent(key) && handler.player.playing) {
      await handler.replaceUpcoming([for (final k in order.skip(next)) byKey[k]!]);
      handler.markShuffled(theirs.shuffled);
      // What the player has now, at their time (not an action here).
      _queues[key] = q;
      _capture(action: false);
      final now = _queues[key]!;
      await _put(key, now.copyWith(at: theirs.at, device: theirs.device));
    } else {
      await _put(key, q);
      if (isCurrent(key)) {
        _adopting = true;
        try {
          await _load2(key, q, byKey, play: false, index: next, position: Duration.zero);
        } finally {
          _adopting = false;
        }
      }
    }
  }

  void dispose() {
    _disposed = true;
    _reconcileSoon?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    if (!_attached) return;
    handler
      ..onSave = null
      ..onNewQueue = null
      ..roundFor = null
      ..onListShuffle = null;
  }
}
