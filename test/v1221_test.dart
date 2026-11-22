// 1.22.1: the Discord status waits for Discord's READY. The fake Discord does
// what the real one does: a command before READY is thrown away, and more
// than two connections a minute get no answer.
import 'dart:convert';
import 'dart:typed_data';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/providers/providers.dart';
import 'package:ouoplayer/services/audio_handler.dart';
import 'package:ouoplayer/services/discord_presence.dart';
// ignore: depend_on_referenced_packages
import 'package:rxdart/rxdart.dart' show BehaviorSubject;

class FakeDiscord {
  FakeDiscord(this.time);
  final FakeAsync time;
  bool running = true;

  /// Answers come in pieces of this size (0: whole).
  int piece = 0;

  /// Answers a connection with 「close」 instead of READY.
  bool closes = false;

  /// Every command Discord took.
  final taken = <Map<String, dynamic>>[];
  var thrownAway = 0;
  final connections = <_FakePipe>[];
  final _accepted = <Duration>[];

  DiscordPipe? open() {
    if (!running) return null;
    final now = time.elapsed;
    _accepted.removeWhere((at) => now - at >= const Duration(minutes: 1));
    final answered = _accepted.length < 2;
    if (answered) _accepted.add(now);
    final pipe = _FakePipe(this, now, answered: answered);
    connections.add(pipe);
    return pipe;
  }
}

class _FakePipe implements DiscordPipe {
  _FakePipe(this.discord, this.openedAt, {required this.answered});
  final FakeDiscord discord;
  final Duration openedAt;
  final bool answered;
  bool closed = false, gone = false, _told = false;
  final _out = <int>[];

  bool get _readyNow => answered && discord.time.elapsed - openedAt >= const Duration(milliseconds: 350);

  @override
  bool write(Uint8List data) {
    if (closed || gone) return false;
    if (ByteData.sublistView(data).getUint32(0, Endian.little) == 0) return true;
    if (_readyNow) {
      discord.taken.add(jsonDecode(utf8.decode(data.sublist(8))) as Map<String, dynamic>);
    } else {
      discord.thrownAway++;
    }
    return true;
  }

  @override
  Uint8List? read() {
    if (closed || gone) return null;
    if (_readyNow && !_told) {
      _told = true;
      _out
        ..addAll(DiscordActivity.frame(1, {'cmd': 'OTHER', 'evt': null}))
        ..addAll(discord.closes
            ? DiscordActivity.frame(2, {'code': 4000, 'message': 'no'})
            : DiscordActivity.frame(1, {'cmd': 'DISPATCH', 'evt': 'READY', 'data': {'user': {'username': '名前'}}}));
    }
    final n = discord.piece == 0 || discord.piece > _out.length ? _out.length : discord.piece;
    final bytes = Uint8List.fromList(_out.sublist(0, n));
    _out.removeRange(0, n);
    return bytes;
  }

  @override
  void close() => closed = true;
}

class _Player implements AudioPlayer {
  @override
  bool playing = true;
  @override
  Duration position = const Duration(seconds: 42);
  @override
  Duration? duration = const Duration(minutes: 4);
  @override
  Stream<bool> get playingStream => Stream.value(playing);
  @override
  Stream<int?> get currentIndexStream => Stream.value(0);
  @override
  Stream<Duration?> get durationStream => Stream.value(duration);
  @override
  Stream<PositionDiscontinuity> get positionDiscontinuityStream => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Handler implements OuoAudioHandler {
  @override
  final _Player player = _Player();
  @override
  Track? currentTrack = _song('first');
  @override
  BehaviorSubject<MediaItem?> get mediaItem => BehaviorSubject.seeded(currentTrack?.toMediaItem());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// An https cover: nothing is looked up on the internet.
Track _song(String title) => Track(id: title, uri: title, title: title, artist: 'yama', art: 'https://x.invalid/$title.jpg', durationMs: 240000);

void main() {
  late FakeDiscord discord;
  late _Handler handler;

  void run(void Function(FakeAsync time) body) => fakeAsync((time) {
        discord = FakeDiscord(time);
        handler = _Handler();
        body(time);
      });

  /// The switch on; call what comes back to turn it off.
  void Function() turnOn() {
    late DiscordPresence presence;
    final made = Provider<DiscordPresence>((ref) => DiscordPresence(ref, open: discord.open)..start());
    final c = ProviderContainer(overrides: [audioHandlerProvider.overrideWithValue(handler)]);
    presence = c.read(made);
    return () {
      presence.dispose();
      c.dispose();
    };
  }

  List<String?> shown() => [for (final m in discord.taken) ((m['args'] as Map)['activity'] as Map?)?['details'] as String?];

  test('開關打開時正在播：第一則就收得到，沒有任何一則被丟掉', () {
    run((time) {
      final off = turnOn();
      time.elapse(const Duration(seconds: 3));
      expect(shown(), ['first']);
      expect(discord.thrownAway, 0);
      off();
    });
  });

  test('準備好之前換歌：送的是當下那首', () {
    run((time) {
      final off = turnOn();
      time.elapse(const Duration(milliseconds: 500));
      handler.currentTrack = _song('second');
      time.elapse(const Duration(seconds: 2));
      expect(shown(), ['second']);
      expect(discord.thrownAway, 0);
      off();
    });
  });

  test('暫停中連上：送清除', () {
    run((time) {
      handler.player.playing = false;
      final off = turnOn();
      time.elapse(const Duration(seconds: 2));
      expect(shown(), [null]);
      expect(discord.thrownAway, 0);
      off();
    });
  });

  test('READY 分好幾次讀到（中文也一樣）', () {
    run((time) {
      discord.piece = 7;
      final off = turnOn();
      time.elapse(const Duration(seconds: 5));
      expect(shown(), ['first']);
      off();
    });
  });

  test('開關連按到被拒絕：不回應時斷開，一分鐘後自己好', () {
    run((time) {
      for (var i = 0; i < 2; i++) {
        final off = turnOn();
        time.elapse(const Duration(seconds: 1));
        off();
        expect(shown().last, isNull, reason: 'turning it off clears');
      }
      discord.taken.clear();
      final off = turnOn();
      time.elapse(const Duration(seconds: 9));
      expect(discord.connections.length, 3);
      expect(discord.connections.last.closed, isFalse);
      time.elapse(const Duration(seconds: 2));
      expect(discord.connections.last.closed, isTrue);
      time.elapse(const Duration(seconds: 55));
      expect(discord.connections.length, 3, reason: 'not knocking while refused');
      time.elapse(const Duration(seconds: 7));
      expect(discord.connections.length, 4);
      expect(shown(), ['first']);
      expect(discord.thrownAway, 0);
      off();
    });
  });

  test('等不到回應時一直有變化：不會一直重連', () {
    run((time) {
      discord
        ..open()
        ..open();
      final conn = DiscordConnection(open: discord.open, onReady: () {});
      for (var i = 0; i < 50; i++) {
        conn.connect();
        time.elapse(const Duration(seconds: 1));
      }
      expect(discord.connections.length, 3);
      conn.close();
    });
  });

  test('Discord 回絕：一分鐘後再連', () {
    run((time) {
      discord.closes = true;
      final off = turnOn();
      time.elapse(const Duration(seconds: 2));
      expect(discord.connections.single.closed, isTrue);
      discord.closes = false;
      time.elapse(const Duration(seconds: 62));
      expect(shown(), ['first']);
      off();
    });
  });

  test('Discord 沒開：之後開了就顯示', () {
    run((time) {
      discord.running = false;
      final off = turnOn();
      time.elapse(const Duration(seconds: 5));
      discord.running = true;
      time.elapse(const Duration(seconds: 20));
      expect(shown(), ['first']);
      off();
    });
  });

  test('Discord 重開：重新連上再送一次', () {
    run((time) {
      final off = turnOn();
      time.elapse(const Duration(seconds: 2));
      discord.connections.single.gone = true;
      time.elapse(const Duration(seconds: 10));
      expect(shown(), ['first', 'first']);
      expect(discord.thrownAway, 0);
      off();
    });
  });

  test('還沒準備好就關掉：什麼都不送、不再連', () {
    run((time) {
      final off = turnOn();
      time.elapse(const Duration(milliseconds: 400));
      off();
      time.elapse(const Duration(minutes: 3));
      expect(discord.taken, isEmpty);
      expect(discord.thrownAway, 0);
      expect(discord.connections.single.closed, isTrue);
    });
  });
}
