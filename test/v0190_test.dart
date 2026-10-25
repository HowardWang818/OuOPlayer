import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/library_scanner.dart';
import 'package:ouoplayer/services/lyrics/lyrics_service.dart';
import 'package:ouoplayer/ui/pages/lyrics_batch_page.dart';
import 'package:path/path.dart' as p;

import 'v0120_test.dart' as v0120;

void main() {
  looseMatching();
  test('batch lyrics skip streams, podcasts and missing songs', () {
    const local = Track(id: '/m/a.mp3', uri: '/m/a.mp3', title: 'a');
    const download = Track(id: '/m/b.m4a', uri: '/m/b.m4a', title: 'b', source: TrackSource.download);
    const stream = Track(id: 'https://x/c.mp3', uri: 'https://x/c.mp3', title: 'c', source: TrackSource.url);
    const episode = Track(id: '/p/e.mp3', uri: '/p/e.mp3', title: 'e', source: TrackSource.podcast);
    const missing = Track(id: 'missing:1', uri: '', title: 'm', source: TrackSource.missing);
    expect([for (final t in lyricsCandidates([local, download, stream, episode, missing])) t.title], ['a', 'b']);
  });

  test('a song with a .lrc beside it already has lyrics', () async {
    final dir = await Directory.systemTemp.createTemp('ouo_lrc');
    addTearDown(() => dir.delete(recursive: true));
    final song = File(p.join(dir.path, 'song.mp3'))..writeAsBytesSync(const [0]);
    File(p.join(dir.path, 'song.lrc')).writeAsStringSync('[00:01.00]hello');
    final service = LyricsService(LibraryScanner(await v0120.openDb()));
    expect(await service.hasLyrics(Track(id: song.path, uri: song.path, title: 'song')), isTrue);
  });
}

LrclibResult hit(String title, String artist, int? secs) => LrclibResult(title: title, artist: artist, album: '', durationSec: secs, synced: '[00:01]x');

void looseMatching() {
  test('a title-only hit needs the same title and the artist or the length', () {
    bool ok(LrclibResult r) => LyricsService.acceptLoose(r, title: 'アイドル', artist: 'Ayase Official', durationMs: 213000);
    // Messy upload titles clean down to the song's title.
    expect(ok(hit('YOASOBI「アイドル」 Official Music Video', 'YOASOBI', 214)), isTrue);
    expect(ok(hit('アイドル - YOASOBI', 'YOASOBI', 213)), isTrue);
    // Another song with the same name but a different length: no.
    expect(ok(hit('アイドル', 'Someone Else', 250)), isFalse);
    // Different title: no, whatever the length.
    expect(ok(hit('群青', 'YOASOBI', 213)), isFalse);
    // Same artist (known spelling) is enough without a length.
    expect(LyricsService.acceptLoose(hit('Lemon', '米津玄師', null), title: 'Lemon', artist: 'Kenshi Yonezu'), isTrue);
  });
}
