// 1.22.2: the Discord status while something plays. Windows' player moves
// the progress about 17 times a second, and just_audio repeats the index
// each time; 1.21.2's 0.3 s wait began again with each and never ended.
// The app's own handler and presence here, on a player that ticks like that.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/providers/providers.dart';
import 'package:ouoplayer/services/audio_handler.dart';
import 'package:ouoplayer/services/discord_presence.dart';

import 'v0120_test.dart' show openDb;
import 'v1220_test.dart' show FakePlatform, FakePlayer, until;

class TickingPlatform extends FakePlatform {
  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async => last = TickingPlayer(request.id);
}

class TickingPlayer extends FakePlayer {
  TickingPlayer(super.id);

  static const every = Duration(milliseconds: 60);
  Timer? _ticker;

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    _ticker ??= Timer.periodic(every, (_) {
      if (state != ProcessingStateMessage.ready) return;
      position += every;
      emit();
    });
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    _ticker?.cancel();
    _ticker = null;
    return PauseResponse();
  }

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    _ticker?.cancel();
    return DisposeResponse();
  }
}

/// A Discord that is ready at once and notes what it is sent.
class ListeningDiscord implements DiscordPipe {
  final sent = <Map<String, dynamic>?>[];
  var _handshake = false;

  @override
  bool write(Uint8List data) {
    if (ByteData.sublistView(data).getUint32(0, Endian.little) == 0) {
      _handshake = true;
    } else {
      sent.add(((jsonDecode(utf8.decode(data.sublist(8))) as Map)['args'] as Map)['activity'] as Map<String, dynamic>?);
    }
    return true;
  }

  @override
  Uint8List? read() {
    if (!_handshake) return Uint8List(0);
    _handshake = false;
    return DiscordActivity.frame(1, {'cmd': 'DISPATCH', 'evt': 'READY'});
  }

  @override
  void close() {}

  List<String?> get titles => [for (final a in sent) a?['details'] as String?];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const session = MethodChannel('com.ryanheise.audio_session');

  late OuoAudioHandler h;
  late ListeningDiscord discord;
  late List<Track> songs;
  ProviderContainer? container;
  DiscordPresence? presence;

  Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  /// The switch on.
  Future<void> turnOn() async {
    final made = Provider<DiscordPresence>((ref) => DiscordPresence(ref, open: () => discord)..start());
    container = ProviderContainer(overrides: [audioHandlerProvider.overrideWithValue(h)]);
    presence = container!.read(made);
    // Connected, ready, and the state of then sent (0.3 s each way).
    await wait(900);
  }

  /// It plays and Discord shows it.
  Future<void> showing() async {
    await h.loadResume(songs, 0, const Duration(seconds: 5));
    await turnOn();
    unawaited(h.play());
    await until(() => discord.titles.contains('song a'), what: 'the song at Discord');
    await wait(400);
    discord.sent.clear();
  }

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(session, (_) async => null);
    JustAudioPlatform.instance = TickingPlatform();
    discord = ListeningDiscord();
    final dir = await Directory.systemTemp.createTemp('ouo_discord');
    songs = [
      for (final n in ['song a', 'song b', 'song c', 'song d'])
        () {
          final f = File('${dir.path}${Platform.pathSeparator}$n.mp3')..writeAsStringSync(n);
          return Track(id: f.path, uri: f.path, title: n, artist: 'yama', art: 'https://x.invalid/$n.jpg');
        }(),
    ];
    h = OuoAudioHandler(await openDb())
      ..fadeMs = 0
      ..recordPlays = false
      ..unplayedFirst = false;
    await wait(50);
  });

  tearDown(() async {
    presence?.dispose();
    presence = null;
    container?.dispose();
    container = null;
    await h.player.pause();
    await wait(50);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(session, null);
  });

  test('一開始播就顯示', () async {
    await h.loadResume(songs, 0, const Duration(seconds: 5));
    await turnOn();
    expect(discord.titles.last, isNull);
    unawaited(h.play());
    await wait(700);
    expect(discord.titles.last, 'song a');
  });

  test('播放中才打開開關：顯示', () async {
    await h.loadResume(songs, 0, Duration.zero);
    unawaited(h.play());
    await wait(300);
    await turnOn();
    await wait(600);
    expect(discord.titles, ['song a']);
  });

  test('點一份清單直接播：顯示', () async {
    await turnOn();
    await h.playTracks(songs);
    await wait(700);
    expect(discord.titles.last, 'song a');
  });

  test('一直播著、進度一直動：不重複送', () async {
    await showing();
    await wait(2500);
    expect(discord.sent, isEmpty);
  });

  test('下一首：馬上換', () async {
    await showing();
    await h.skipToNext();
    await wait(700);
    expect(discord.titles, ['song b']);
  });

  test('連按下一首：只送最後那首', () async {
    await showing();
    await h.skipToNext();
    await wait(40);
    await h.skipToNext();
    await wait(40);
    await h.skipToNext();
    await wait(700);
    expect(discord.titles, ['song d']);
  });

  test('拖進度：進度跟著改', () async {
    await showing();
    await h.seek(const Duration(seconds: 90));
    await wait(700);
    expect(discord.titles, ['song a']);
    final start = (discord.sent.single!['timestamps'] as Map)['start'] as int;
    expect((DateTime.now().millisecondsSinceEpoch - start) / 1000, closeTo(90, 3));
  });

  test('暫停清掉，再播又顯示', () async {
    await showing();
    await h.pause();
    await wait(700);
    expect(discord.titles, [null]);
    unawaited(h.play());
    await wait(700);
    expect(discord.titles, [null, 'song a']);
  });

  test('換一份清單、同一個位置的另一首：換成那首', () async {
    await showing();
    await h.playTracks([songs[2], songs[3]]);
    await wait(900);
    expect(discord.titles.last, 'song c');
  });

  test('改歌名：跟著改', () async {
    await showing();
    h.updateTrackInfo(Track(id: songs[0].id, uri: songs[0].uri, title: 'renamed', artist: 'yama', art: songs[0].art));
    await wait(700);
    expect(discord.titles, ['renamed']);
  });

  test('歌詞列一直換行：不佔 Discord 的額度', () async {
    await showing();
    for (var i = 0; i < 4; i++) {
      h.showLyricLine('line $i');
      await wait(400);
    }
    expect(discord.sent, isEmpty);
  });
}
