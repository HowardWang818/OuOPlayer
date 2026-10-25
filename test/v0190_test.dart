import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/library_scanner.dart';
import 'package:ouoplayer/services/lyrics/lyrics_service.dart';
import 'package:ouoplayer/ui/pages/lyrics_batch_page.dart';
import 'package:path/path.dart' as p;

import 'v0120_test.dart' as v0120;

void main() {
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
