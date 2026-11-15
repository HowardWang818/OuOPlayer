// 1.20.14: songs are measured as soon as they come in; downloaded songs get
// their measurement written into the file (ReplayGain); tag edits keep it;
// a song found quieter mid-song is raised slowly.
import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/loudness.dart';
import 'package:ouoplayer/services/replay_gain.dart';
import 'package:ouoplayer/services/replay_gain_writer.dart';
import 'package:ouoplayer/services/tag_editor.dart';
import 'package:ouoplayer/services/volume_normalizer.dart';

import 'v0120_test.dart' show openDb;

const _l = SongLoudness(-9.37, -0.42);

late Directory _dir;

File _copy(String name) => File('test/fixtures/$name').copySync('${_dir.path}/${DateTime.now().microsecondsSinceEpoch}_$name');

Track _song(File f, {String source = TrackSource.download}) =>
    Track(id: f.path, uri: f.path, title: 'Tone', artist: 'Test', album: 'x', durationMs: 1000, source: source, addedAt: 1);

/// The chunk offsets of an .m4a and the 16 bytes each points at.
List<(int, List<int>)> _chunks(Uint8List b) {
  final d = ByteData.sublistView(b);
  final out = <(int, List<int>)>[];
  for (var i = 0; i + 8 < b.length; i++) {
    if (b[i] == 0x73 && b[i + 1] == 0x74 && b[i + 2] == 0x63 && b[i + 3] == 0x6f) {
      final n = d.getUint32(i + 8);
      for (var k = 0; k < n; k++) {
        final at = d.getUint32(i + 12 + k * 4);
        out.add((at, b.sublist(at, at + 16)));
      }
      break;
    }
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    _dir = Directory.systemTemp.createTempSync('v12014');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (call) async => _dir.path);
  });
  tearDown(() {
    try {
      _dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('ReplayGain written into the file', () {
    for (final name in ['tone.m4a', 'tone.mp3', 'tone.opus', 'tone.ogg', 'tone.flac']) {
      test(name, () {
        final f = _copy(name);
        final before = readMetadata(f);
        // Twice: the second replaces the first.
        f.writeAsBytesSync(withReplayGain(f.path, f.readAsBytesSync(), const SongLoudness(-20, -3))!);
        f.writeAsBytesSync(withReplayGain(f.path, f.readAsBytesSync(), _l)!);
        final back = replayGainOf(f.path)!;
        expect(back.lufs, closeTo(_l.lufs, 0.01));
        expect(back.peak, closeTo(_l.peak, 0.01));
        final after = readMetadata(f);
        expect(after.title, before.title);
        expect(after.artist, before.artist);
        expect(after.duration, before.duration);
      });
    }

    test('m4a: the audio after the tags is still found (chunk offsets)', () {
      final f = _copy('tone.m4a');
      final before = _chunks(f.readAsBytesSync());
      expect(before, isNotEmpty);
      final out = withReplayGain(f.path, f.readAsBytesSync(), _l)!;
      final after = _chunks(out);
      expect(after.length, before.length);
      for (var i = 0; i < before.length; i++) {
        expect(after[i].$2, before[i].$2, reason: 'chunk $i');
        expect(after[i].$1, isNot(before[i].$1), reason: 'moov comes first here, so the audio moved');
      }
    });

    test('mp3: the audio bytes stay as they were', () {
      final f = _copy('tone.mp3');
      final b = f.readAsBytesSync();
      final out = withReplayGain(f.path, b, _l)!;
      final tail = b.sublist(b.length - 2000);
      expect(out.sublist(out.length - 2000), tail);
    });

    test('formats it can\'t take: nothing', () {
      expect(withReplayGain('a.webm', Uint8List(10), _l), isNull);
      expect(withReplayGain('a.m4a', Uint8List.fromList(List.filled(20, 1)), _l), isNull);
    });
  });

  test('編輯資訊 keeps the ReplayGain the file had', () async {
    for (final name in ['tone.m4a', 'tone.mp3', 'tone.flac']) {
      final f = _copy(name);
      f.writeAsBytesSync(withReplayGain(f.path, f.readAsBytesSync(), _l)!);
      await writeTags(f.path, const TagEdit(title: '新名字', artist: '歌手', album: '專輯'));
      expect(readMetadata(f).title, '新名字', reason: name);
      expect(replayGainOf(f.path)?.lufs, closeTo(_l.lufs, 0.01), reason: name);
    }
  });

  test('writeReplayGainQuietly checks the copy and writes it', () async {
    final f = _copy('tone.m4a');
    expect(await writeReplayGainQuietly(f.path, _l), isTrue);
    expect(replayGainOf(f.path)!.lufs, closeTo(_l.lufs, 0.01));
    final w = File('${_dir.path}/a.webm')..writeAsBytesSync([1, 2, 3]);
    expect(await writeReplayGainQuietly(w.path, _l), isFalse);
  });

  group('measured as soon as songs come in', () {
    test('a new song is picked up without anything playing', () async {
      final db = await openDb();
      final s = LoudnessService(db)..start(first: const Duration(milliseconds: 10), settle: const Duration(milliseconds: 10));
      addTearDown(s.stop);
      final f = _copy('tone.opus');
      f.writeAsBytesSync(withReplayGain(f.path, f.readAsBytesSync(), _l)!);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await db.upsertTracks([_song(f)]);
      for (var i = 0; i < 100 && await db.loudness(f.path) == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect((await db.loudness(f.path))?.lufs, closeTo(_l.lufs, 0.01));
    });

    test('downloads measured before: written once; the playing song waits; own files never', () async {
      final db = await openDb();
      final down = _copy('tone.m4a'), playing = _copy('tone.mp3'), own = _copy('tone.flac');
      await db.upsertTracks([_song(down), _song(playing), _song(own, source: TrackSource.local)]);
      for (final f in [down, playing, own]) {
        await db.setLoudness(f.path, _l.lufs, _l.peak);
      }
      final written = <String>[];
      final s = LoudnessService(db)
        ..writeFile = ((path, l) async {
          written.add(path);
          return true;
        })
        ..busy = ((id) => id == playing.path);
      await s.writeWaiting();
      expect(written, [down.path]);
      s.busy = (_) => false;
      await s.writeWaiting();
      expect(written, [down.path, playing.path]);
      await s.writeWaiting();
      expect(written, [down.path, playing.path], reason: 'once');
    });
  });

  test('raised slowly mid-song, lowered within a second', () {
    expect(rampTime(-6, 3), raiseTime);
    expect(raiseTime, const Duration(seconds: 5));
    expect(rampTime(0, -4), const Duration(seconds: 1));
  });
}
