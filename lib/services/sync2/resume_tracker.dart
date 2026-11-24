import 'dart:async';
import 'dart:convert';

import '../../data/db/database.dart';
import '../../data/models/track.dart';
import '../audio_handler.dart';
import 'engine.dart' show SyncEngine;
import 'now_playing.dart';

/// Follows the player for 接續播放 (1.23.0): how long really played here, the
/// last real progress, and the progress that was replaced or not chosen
/// (設定 → 同步 → 接續播放狀態 brings it back).
///
/// All of it stays in this device's settings, so progress that didn't reach
/// Drive before the app was closed goes up when it opens again.
class ResumeTracker {
  ResumeTracker(this.db, this.handler, {required this.deviceId, required this.deviceName, DateTime Function()? clock})
      : clock = clock ?? DateTime.now {
    handler
      ..onSave = flush
      ..onNewQueue = _newQueue;
    _playing = handler.player.playingStream.distinct().listen(_playingChanged);
    _index = handler.player.currentIndexStream.distinct().skip(1).listen((_) => flush());
    ready = _load();
  }

  final AppDatabase db;
  final OuoAudioHandler handler;
  final Future<String> Function() deviceId;
  final String deviceName;
  final DateTime Function() clock;

  /// A run just began to count: worth sending at once.
  void Function()? onCounts;

  late final Future<void> ready;
  ResumeState state = ResumeState();
  List<NowPlaying> kept = [];

  /// `sync2_*` stays out of backups.
  static const stateKey = 'sync2_now';
  static const keptKey = 'sync2_now_kept';
  static const _keep = 4;

  /// A pause this short is the same listening.
  static const _sameListening = Duration(minutes: 1);

  /// The most one look can add (the PC slept while playing).
  static const _longest = Duration(minutes: 2);

  late final StreamSubscription<bool> _playing;
  late final StreamSubscription<int?> _index;
  bool _loaded = false;
  bool _disposed = false;
  String _me = '';
  DateTime? _since;
  DateTime? _stoppedAt;

  /// The current queue has played since it was loaded: only then is it
  /// captured (a queue just restored still says second 0 for a moment).
  bool _played = false;

  Future<void> _load() async {
    try {
      _me = await deviceId();
      final s = await db.allSettings();
      final raw = s[stateKey];
      if (raw != null) state = ResumeState.fromJson(jsonDecode(raw) as Map);
      final old = s[keptKey];
      if (old != null) {
        kept = [for (final j in jsonDecode(old) as List) NowPlaying.fromJson(j as Map)].nonNulls.toList();
      }
      // Closed while playing: it doesn't any more.
      final snap = state.snap;
      if (snap != null && snap.playing && !handler.player.playing) {
        state
          ..snap = snap.copyWith(playing: false)
          ..rev += 1;
      }
    } catch (_) {
      // Unreadable: from nothing.
    }
    _loaded = true;
  }

  bool get _countable {
    final list = handler.queueTracks;
    return !handler.previewing && list.isNotEmpty && !list.every((t) => t.isRemote);
  }

  void _playingChanged(bool on) {
    if (on) {
      if (_since != null || !_countable) return;
      final now = clock();
      final stopped = _stoppedAt;
      if (state.session == null || stopped == null || now.difference(stopped) > _sameListening) {
        state.session = '${now.millisecondsSinceEpoch}';
      }
      _since = now;
      _played = true;
      return;
    }
    if (_since != null) _stoppedAt = clock();
    flush();
  }

  /// Counts up to now and, if it counts, takes what plays as the progress.
  void flush() {
    if (!_loaded || _disposed) return;
    final now = clock();
    final since = _since;
    final playing = handler.player.playing && _countable;
    final before = state.counts;
    if (since != null) {
      final gone = now.difference(since);
      final ms = (gone > _longest ? _longest : gone).inMilliseconds;
      if (ms > 0) state.heard(ms, now.millisecondsSinceEpoch);
    }
    // Also picks up a playing queue that couldn't count a moment ago.
    _since = playing ? now : null;
    if (playing) _played = true;
    if (state.counts && _played && _countable && !handler.loadingQueue) {
      final snap = here(at: state.at ?? now.millisecondsSinceEpoch);
      if (snap != null && jsonEncode(snap.toJson()) != jsonEncode(state.snap?.toJson())) {
        state
          ..snap = snap
          ..rev += 1;
      }
    }
    _save();
    if (!before && state.counts) onCounts?.call();
  }

  /// Another queue is about to take the player's place. [pickUp]: a progress
  /// picked up, which is played here only after 30 seconds of it.
  void _newQueue({required bool pickUp}) {
    flush();
    // Tries that didn't count add up.
    if (pickUp || state.counts) state.run = 0;
    _played = false;
    _since = null;
    _stoppedAt = null;
    if (!pickUp && handler.player.playing) {
      // Playing goes straight on into the new queue.
      final now = clock();
      state.session = '${now.millisecondsSinceEpoch}';
      _since = now;
      _played = true;
    }
  }

  /// What is in the player now, whether it counts or not.
  NowPlaying? here({int? at}) {
    final list = handler.queueTracks;
    if (list.isEmpty || handler.previewing || list.every((Track t) => t.isRemote)) return null;
    final play = handler.currentPlay;
    return NowPlaying(
      device: _me,
      deviceName: deviceName,
      at: at ?? handler.lastPlayedAt?.millisecondsSinceEpoch ?? clock().millisecondsSinceEpoch,
      songs: [for (final t in list) SyncEngine.ref(t)],
      index: handler.player.currentIndex ?? 0,
      positionMs: handler.player.position.inMilliseconds,
      original: handler.originalOrder,
      loop: handler.player.loopMode.name,
      began: play?.began,
      heardMs: play?.heard ?? 0,
      playing: handler.player.playing,
    );
  }

  /// [n] with how long each device heard that play.
  Future<NowPlaying> withParts(NowPlaying n) async {
    final began = n.began;
    if (began == null) return n;
    final parts = await db.playParts(began, _me);
    return parts == null ? n : n.copyWith(parts: parts);
  }

  /// Settles [offers]; with one [took], this device's own progress is given up.
  void settle(Iterable<NowPlaying> offers, {NowPlaying? took}) {
    for (final o in offers) {
      if (o.device == _me) continue;
      state.settle(o, took: identical(o, took));
    }
    if (took != null) {
      state
        ..over = true
        ..rev += 1;
    }
    _save();
  }

  /// Not asked again about this listening (取消: nothing is decided).
  void hush(Iterable<NowPlaying> offers) {
    for (final o in offers) {
      state.quiet[o.device] = o.sessionKey;
    }
    _save();
  }

  /// For 換回: the newest [_keep], one per listening of a device.
  Future<void> keep(Iterable<NowPlaying> list) async {
    final before = jsonEncode([for (final n in kept) n.toJson()]);
    for (final n in list) {
      kept
        ..removeWhere((k) => k.device == n.device && (n.session != null ? k.session == n.session : sameProgress(k, n)))
        ..insert(0, n);
    }
    if (kept.length > _keep) kept = kept.sublist(0, _keep);
    final after = jsonEncode([for (final n in kept) n.toJson()]);
    if (after != before) await db.setSetting(keptKey, after);
  }

  void markSent(int rev) {
    state.sent = rev;
    _save();
  }

  String? _saved;

  void _save() {
    if (_disposed || !_loaded) return;
    final json = jsonEncode(state.toJson());
    if (json == _saved) return;
    _saved = json;
    db.setSetting(stateKey, json).catchError((_) {
      _saved = null;
    });
  }

  void dispose() {
    _disposed = true;
    handler
      ..onSave = null
      ..onNewQueue = null;
    _playing.cancel();
    _index.cancel();
  }
}

/// The same song at about the same second.
bool sameProgress(NowPlaying a, NowPlaying b) =>
    a.current['t'] == b.current['t'] && a.current['a'] == b.current['a'] && (a.positionMs - b.positionMs).abs() < 2000;
