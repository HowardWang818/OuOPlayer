import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/discord_config.dart';
import '../data/models/track.dart';
import '../providers/providers.dart';
import 'cover_finder.dart';
import 'listen_link.dart';
import 'song_matcher.dart' show MatchLevel;

/// 「在 Discord 顯示正在聽的歌」 (1.21.0, Windows): the song playing here as
/// the Discord status — 「Listening to OuOPlayer」, the title and artist, the
/// cover when it is on the internet, a progress bar and 「Open OuOPlayer」
/// for the others. Nothing while paused. Through Discord's own Rich Presence
/// pipe on this computer; Discord on phones has no such thing.
class DiscordActivity {
  /// The activity for [track] at [position], or null when there is none to
  /// show (nothing playing, or paused).
  static Map<String, Object?>? of(Track? track, {required bool playing, required Duration position, Duration? duration, String? cover, required int nowMs}) {
    if (track == null || !playing) return null;
    final start = nowMs - position.inMilliseconds;
    final length = duration ?? (track.durationMs == null ? null : Duration(milliseconds: track.durationMs!));
    final button = ListenLink.webUrl(track);
    return {
      'type': 2, // Listening
      // The member list shows the song, not 「OuOPlayer」 (1.21.1).
      'status_display_type': 2,
      'details': _text(track.title),
      if (_artist(track) != null) 'state': _text(_artist(track)!),
      'timestamps': {
        'start': start,
        if (length != null && length > Duration.zero) 'end': start + length.inMilliseconds,
      },
      'assets': {'large_image': cover ?? discordIconUrl},
      if (button.length <= 512) 'buttons': [
        {'label': 'Open OuOPlayer', 'url': button},
      ],
    };
  }

  static String? _artist(Track t) {
    final a = t.artist.trim();
    return a.isEmpty || a == '未知演出者' ? null : a;
  }

  /// Discord takes 2 to 128 characters.
  static String _text(String s) {
    final t = s.trim();
    final cut = t.runes.length > 128 ? '${String.fromCharCodes(t.runes.take(127))}…' : t;
    return cut.runes.length < 2 ? '$cut ' : cut;
  }

  /// One message on the pipe: opcode, length (little-endian), JSON.
  static Uint8List frame(int op, Map<String, Object?> body) {
    final json = utf8.encode(jsonEncode(body));
    final out = ByteData(8 + json.length)
      ..setInt32(0, op, Endian.little)
      ..setInt32(4, json.length, Endian.little);
    final bytes = out.buffer.asUint8List()..setRange(8, 8 + json.length, json);
    return bytes;
  }

  static Map<String, Object?> setActivity(Map<String, Object?>? activity, {required int pid, required String nonce}) => {
        'cmd': 'SET_ACTIVITY',
        'args': {'pid': pid, 'activity': activity},
        'nonce': nonce,
      };
}

/// Discord takes about 5 changes per 20 seconds (1.21.1: before, one at
/// most every 4 seconds, so a song change or pause showed late).
class SendWindow {
  SendWindow({this.max = 5, this.span = const Duration(seconds: 20)});
  final int max;
  final Duration span;
  final _at = <DateTime>[];

  /// How long a change made [now] waits: none while there is room.
  Duration wait(DateTime now) {
    _at.removeWhere((t) => now.difference(t) >= span);
    return _at.length < max ? Duration.zero : span - now.difference(_at.first);
  }

  void sent(DateTime now) => _at.add(now);
}

/// The songs' covers on the internet for the Discord status (1.21.2): one
/// lookup per song at a time (1.21.1 ran several at once, iTunes turned
/// them away, and the song was then remembered as having no cover). A
/// lookup that failed is tried again after a minute; only 「none found」 is
/// remembered.
class CoverLookup {
  CoverLookup(this._find, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  /// The cover's address, null when there is none; throws when it can't tell.
  final Future<String?> Function(Track t) _find;
  final DateTime Function() _clock;
  final _found = <String, String?>{};
  final _running = <String, Future<String?>>{};
  final _failedAt = <String, DateTime>{};

  static const retryAfter = Duration(minutes: 1);

  /// The cover already known (null: none yet, or none at all).
  String? known(Track t) => t.art != null && t.art!.startsWith('https://') ? t.art : _found[t.id];

  /// Nothing more to look up for [t] now.
  bool settled(Track t) {
    if (known(t) != null || _found.containsKey(t.id)) return true;
    final failed = _failedAt[t.id];
    return failed != null && _clock().difference(failed) < retryAfter;
  }

  Future<String?> get(Track t) {
    if (settled(t)) return Future.value(known(t));
    return _running[t.id] ??= () async {
      try {
        final url = await _find(t);
        _found[t.id] = url;
        _failedAt.remove(t.id);
        return url;
      } catch (_) {
        _failedAt[t.id] = _clock();
        return null;
      } finally {
        _running.remove(t.id);
      }
    }();
  }
}

// ---------- the pipe (Windows) ----------

typedef _CreateFileC = IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, IntPtr);
typedef _CreateFileD = int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int);
typedef _RwC = Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>);
typedef _RwD = int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>);
typedef _PeekC = Int32 Function(IntPtr, Pointer<Void>, Uint32, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>);
typedef _PeekD = int Function(int, Pointer<Void>, int, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>);
typedef _CloseC = Int32 Function(IntPtr);
typedef _CloseD = int Function(int);

/// One open pipe to Discord.
abstract interface class DiscordPipe {
  bool write(Uint8List data);

  /// What Discord sent, without waiting (empty: nothing); null: the pipe is gone.
  Uint8List? read();

  void close();
}

/// The pipe's life (1.22.1). A command that comes before Discord's READY
/// (0.3–0.4 s after the handshake) is thrown away by Discord, so nothing is
/// sent until then. Discord takes about two connections a minute from one
/// app and doesn't answer more: no READY in [readyWait] means again after
/// [refusedWait].
class DiscordConnection {
  DiscordConnection({required DiscordPipe? Function() open, required void Function() onReady})
      : _open = open,
        _onReady = onReady;

  final DiscordPipe? Function() _open;

  /// Discord listens now: the state of that moment goes out.
  final void Function() _onReady;

  static const readyWait = Duration(seconds: 10);
  static const refusedWait = Duration(minutes: 1);
  static const notRunningWait = Duration(seconds: 20);
  static const lostWait = Duration(seconds: 1);
  static const _readyPoll = Duration(milliseconds: 50);
  static const _poll = Duration(seconds: 5);

  DiscordPipe? _pipe;
  Timer? _reading, _deadline, _retry;
  var _got = Uint8List(0);
  bool _ready = false;
  bool _closed = false;

  bool get ready => _ready;

  /// Connects, unless that is under way or waiting for its turn.
  void connect() {
    if (_closed || _pipe != null || _retry != null) return;
    final p = _open();
    // Discord not running (yet): looked for again in a while.
    if (p == null) return _again(notRunningWait);
    if (!p.write(DiscordActivity.frame(0, {'v': 1, 'client_id': discordAppId}))) {
      p.close();
      return _again(notRunningWait);
    }
    _pipe = p;
    _deadline = Timer(readyWait, () => _drop(refusedWait));
    _reading = Timer.periodic(_readyPoll, (_) => _read());
  }

  void send(Map<String, Object?> body) {
    if (!_ready) return;
    if (!_pipe!.write(DiscordActivity.frame(1, body))) _drop(lostWait);
  }

  void _read() {
    final bytes = _pipe?.read();
    if (bytes == null) return _drop(_ready ? lostWait : refusedWait);
    // After READY the replies are only taken off the pipe.
    if (_ready || bytes.isEmpty) return;
    _got = Uint8List.fromList([..._got, ...bytes]);
    while (_got.length >= 8) {
      final head = ByteData.sublistView(_got);
      final op = head.getUint32(0, Endian.little);
      final end = 8 + head.getUint32(4, Endian.little);
      if (_got.length < end) return;
      final body = _got.sublist(8, end);
      _got = _got.sublist(end);
      if (op == 2) return _drop(refusedWait); // Discord closes it.
      if (op == 1 && _isReady(body)) {
        _ready = true;
        _got = Uint8List(0);
        _deadline?.cancel();
        _reading?.cancel();
        _reading = Timer.periodic(_poll, (_) => _read());
        _onReady();
        return;
      }
    }
  }

  static bool _isReady(Uint8List body) {
    try {
      final message = jsonDecode(utf8.decode(body));
      return message is Map && message['evt'] == 'READY';
    } catch (_) {
      return false;
    }
  }

  void _drop(Duration wait) {
    _release();
    _again(wait);
  }

  void _again(Duration wait) {
    if (_closed) return;
    _retry ??= Timer(wait, () {
      _retry = null;
      connect();
    });
  }

  void _release() {
    _deadline?.cancel();
    _reading?.cancel();
    _pipe?.close();
    _pipe = null;
    _ready = false;
    _got = Uint8List(0);
  }

  void close() {
    _closed = true;
    _retry?.cancel();
    _release();
  }
}

class WindowsDiscordPipe implements DiscordPipe {
  WindowsDiscordPipe._(this._handle);
  final int _handle;

  static final _k = DynamicLibrary.open('kernel32.dll');
  static final _create = _k.lookupFunction<_CreateFileC, _CreateFileD>('CreateFileW');
  static final _write = _k.lookupFunction<_RwC, _RwD>('WriteFile');
  static final _read = _k.lookupFunction<_RwC, _RwD>('ReadFile');
  static final _peek = _k.lookupFunction<_PeekC, _PeekD>('PeekNamedPipe');
  static final _close = _k.lookupFunction<_CloseC, _CloseD>('CloseHandle');

  /// Discord's pipe (discord-ipc-0 … 9), or null when Discord isn't running.
  static WindowsDiscordPipe? open() {
    for (var i = 0; i < 10; i++) {
      final name = r'\\.\pipe\discord-ipc-' '$i'.toNativeUtf16();
      try {
        final h = _create(name, 0x80000000 | 0x40000000, 0, nullptr, 3, 0, 0);
        if (h != -1 && h != 0) return WindowsDiscordPipe._(h);
      } finally {
        calloc.free(name);
      }
    }
    return null;
  }

  @override
  bool write(Uint8List data) {
    final buf = calloc<Uint8>(data.length);
    final done = calloc<Uint32>();
    try {
      buf.asTypedList(data.length).setAll(0, data);
      return _write(_handle, buf, data.length, done, nullptr) != 0 && done.value == data.length;
    } finally {
      calloc.free(buf);
      calloc.free(done);
    }
  }

  @override
  Uint8List? read() {
    final avail = calloc<Uint32>();
    try {
      if (_peek(_handle, nullptr, 0, nullptr, avail, nullptr) == 0) return null;
      final n = avail.value;
      if (n == 0) return Uint8List(0);
      final buf = calloc<Uint8>(n);
      final got = calloc<Uint32>();
      try {
        if (_read(_handle, buf, n, got, nullptr) == 0) return null;
        return Uint8List.fromList(buf.asTypedList(got.value));
      } finally {
        calloc.free(buf);
        calloc.free(got);
      }
    } finally {
      calloc.free(avail);
    }
  }

  @override
  void close() => _close(_handle);
}

// ---------- the service ----------

/// 在 Discord 顯示正在聽的歌 (off unless turned on).
final discordPresenceOnProvider = NotifierProvider<DiscordPresenceOn, bool>(DiscordPresenceOn.new);

class DiscordPresenceOn extends Notifier<bool> {
  static const key = 'discord_presence';

  /// Offered on Windows, once OuOPlayer has its Discord application.
  static bool get offered => Platform.isWindows && discordAppId.isNotEmpty;

  @override
  bool build() {
    ref.read(dbProvider).allSettings().then((s) => state = s[key] == 'true');
    return false;
  }

  Future<void> set(bool on) async {
    state = on;
    await ref.read(dbProvider).setSetting(key, '$on');
  }
}

/// Keeps the Discord status in step with what plays.
final discordPresenceProvider = Provider<void>((ref) {
  if (!DiscordPresenceOn.offered) return;
  final on = ref.watch(discordPresenceOnProvider);
  final presence = DiscordPresence(ref);
  ref.onDispose(presence.dispose);
  if (on) presence.start();
});

class DiscordPresence {
  DiscordPresence(this._ref, {DiscordPipe? Function() open = WindowsDiscordPipe.open}) : _open = open;
  final Ref _ref;
  final DiscordPipe? Function() _open;
  late final _connection = DiscordConnection(open: _open, onReady: _soon);
  final _subs = <StreamSubscription<Object?>>[];
  Timer? _later;
  final _window = SendWindow();
  late final _covers = CoverLookup((t) async {
    final hit = await CoverFinder(_ref.read(iTunesSearchProvider), pause: Duration.zero).find(t);
    return hit != null && hit.level == MatchLevel.sure ? hit.song.artwork : null;
  });

  /// Changes this close together go out as one (1.21.2: a song change
  /// brings several at once).
  static const settle = Duration(milliseconds: 300);
  var _nonce = 0;
  bool _live = true;

  void start() {
    final handler = _ref.read(audioHandlerProvider);
    final player = handler.player;
    _subs
      ..add(player.playingStream.listen((_) => _soon()))
      // The index comes again with every move of the progress (about 17 a
      // second on Windows): only a different one is a change (1.22.2).
      ..add(player.currentIndexStream.distinct().listen((_) => _soon()))
      // Another song in the same place (a new queue, a preview), or renamed;
      // not the lyric line that may stand in for the artist.
      ..add(handler.mediaItem.map((item) {
        final track = item?.extras?['track'];
        return (item?.id, item?.title, track is Map ? track['artist'] : null);
      }).distinct().listen((_) => _soon()))
      ..add(player.durationStream.listen((_) => _soon()))
      ..add(player.positionDiscontinuityStream.listen((_) => _soon()));
    _soon();
  }

  void dispose() {
    _live = false;
    for (final s in _subs) {
      s.cancel();
    }
    _later?.cancel();
    _connection.send(DiscordActivity.setActivity(null, pid: pid, nonce: '${_nonce++}'));
    _connection.close();
  }

  /// [settle] after the first change while there is room ([SendWindow]),
  /// otherwise once there is: the state of that moment. More changes don't
  /// put it off (1.21.2 counted from the last one, so while a song played
  /// nothing went out).
  void _soon() {
    if (!_live || (_later?.isActive ?? false)) return;
    final wait = _window.wait(DateTime.now());
    _later = Timer(wait > settle ? wait : settle, () => unawaited(_send()));
  }

  /// The state now. A new song goes out without waiting for its cover: the
  /// cover follows once found.
  Future<void> _send() async {
    if (!_live) return;
    if (!_connection.ready) {
      // Once Discord is ready, what plays then goes out.
      _connection.connect();
      return;
    }
    final handler = _ref.read(audioHandlerProvider);
    final track = handler.currentTrack;
    final playing = handler.player.playing;
    final activity = DiscordActivity.of(track,
        playing: playing,
        position: handler.player.position,
        duration: handler.player.duration,
        cover: track == null ? null : _covers.known(track),
        nowMs: DateTime.now().millisecondsSinceEpoch);
    _window.sent(DateTime.now());
    _connection.send(DiscordActivity.setActivity(activity, pid: pid, nonce: '${_nonce++}'));
    if (track == null || !playing || _covers.settled(track)) return;
    final url = await _covers.get(track);
    if (url != null && _live && handler.currentTrack?.id == track.id && handler.player.playing) _soon();
  }

}
