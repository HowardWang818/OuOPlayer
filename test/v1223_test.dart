// 1.22.3: a 試聽 isn't shown on Discord, and 「nothing to show」 isn't said
// twice on one connection: several previews would use up Discord's five
// changes in 20 seconds, and the song played next would show late.
import 'dart:async';
import 'dart:io';

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
import 'v1220_test.dart' show until;
import 'v1222_test.dart' show ListeningDiscord, TickingPlatform;

class RestartingDiscord extends ListeningDiscord {
  bool gone = false;

  @override
  Uint8List? read() {
    if (!gone) return super.read();
    gone = false;
    return null;
  }
}

/// A preview; without [art] a cover would have to be looked up.
Track preview(String name, {bool art = true}) => Track.fromUrl('https://preview.test/$name.m4a',
    title: '$name（試聽）', art: art ? 'https://x.invalid/$name.jpg' : null, source: TrackSource.preview);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const session = MethodChannel('com.ryanheise.audio_session');

  late OuoAudioHandler h;
  late RestartingDiscord discord;
  late List<Track> songs;
  late ProviderContainer container;
  late DiscordPresence presence;
  var coverLookups = 0;

  Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  Future<void> listen() async {
    unawaited(h.play());
    await until(() => discord.titles.contains('song a'), what: 'the song at Discord');
  }

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(session, (_) async => null);
    JustAudioPlatform.instance = TickingPlatform();
    discord = RestartingDiscord();
    coverLookups = 0;
    final dir = await Directory.systemTemp.createTemp('ouo_discord_preview');
    songs = [
      for (final n in ['song a', 'song b'])
        () {
          final f = File('${dir.path}${Platform.pathSeparator}$n.mp3')..writeAsStringSync(n);
          return Track(id: f.path, uri: f.path, title: n, artist: 'yama', art: 'https://x.invalid/cover.jpg');
        }(),
    ];
    h = OuoAudioHandler(await openDb())
      ..fadeMs = 0
      ..recordPlays = false;
    await wait(50);
    await h.loadResume(songs, 0, const Duration(seconds: 5));
    final made = Provider<DiscordPresence>((ref) => DiscordPresence(ref, open: () => discord)..start());
    container = ProviderContainer(overrides: [
      audioHandlerProvider.overrideWithValue(h),
      iTunesSearchProvider.overrideWith((ref) {
        coverLookups++;
        throw StateError('no internet in tests');
      }),
    ]);
    presence = container.read(made);
    await wait(900);
  });

  tearDown(() async {
    presence.dispose();
    container.dispose();
    await h.player.pause();
    await wait(50);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(session, null);
  });

  test('試聽中：什麼都不顯示', () async {
    await listen();
    await h.playPreview(preview('p1'));
    await wait(1200);
    expect(discord.titles.last, isNull);
    expect(discord.titles.whereType<String>().toSet(), {'song a'});
  });

  test('不替試聽查封面', () async {
    await h.playPreview(preview('p1', art: false));
    await wait(1000);
    expect(coverLookups, 0);
    expect(discord.titles.whereType<String>(), isEmpty);
  });

  test('連續試聽、回來：清除只送一次', () async {
    await listen();
    await wait(400);
    discord.sent.clear();
    for (final name in ['p1', 'p2', 'p3', 'p4']) {
      await h.playPreview(preview(name));
      await wait(500);
    }
    await h.skipToNext();
    await wait(800);
    expect(discord.titles, [null]);
  });

  test('連續試聽後按播放：一秒內顯示', () async {
    await listen();
    for (final name in ['p1', 'p2', 'p3', 'p4']) {
      await h.playPreview(preview(name));
      await wait(400);
    }
    await h.skipToNext();
    await wait(700);
    unawaited(h.play());
    await wait(1000);
    expect(discord.titles.last, 'song a');
  });

  test('試聽中改播別首：顯示那首', () async {
    await listen();
    await h.playPreview(preview('p1'));
    await wait(700);
    await h.playTracks([songs[1]]);
    await wait(900);
    expect(discord.titles.last, 'song b');
  });

  test('暫停照常清掉', () async {
    await listen();
    await h.pause();
    await wait(700);
    expect(discord.titles, [null, 'song a', null]);
  });

  test('重新連線：照樣送一次清除', () async {
    expect(discord.titles, [null]);
    discord.gone = true;
    // Noticed within 5 s, connected again a second later.
    await wait(7500);
    expect(discord.titles, [null, null]);
  });
}
