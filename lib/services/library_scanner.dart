import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/db/database.dart';
import '../data/models/track.dart';

const audioExtensions = {'.mp3', '.flac', '.m4a', '.aac', '.ogg', '.opus', '.wav', '.wma', '.mp4'};

class ScanProgress {
  final int done;
  final int total;
  final bool running;
  const ScanProgress(this.done, this.total, this.running);
  static const idle = ScanProgress(0, 0, false);
}

/// Walks music folders, reads tags + cover art in a background isolate and stores
/// results in the database.
class LibraryScanner {
  LibraryScanner(this._db);

  final AppDatabase _db;
  final _progress = StreamController<ScanProgress>.broadcast();
  Stream<ScanProgress> get progress => _progress.stream;
  bool _running = false;

  Future<String> _artDir() async {
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'art'));
    await dir.create(recursive: true);
    return dir.path;
  }

  Future<int> scan(List<String> folders, {bool removeMissing = true}) async {
    if (_running) return 0;
    _running = true;
    try {
      _progress.add(const ScanProgress(0, 0, true));
      final files = <String>[];
      for (final f in folders) {
        final dir = Directory(f);
        if (!await dir.exists()) continue;
        try {
          await for (final e in dir.list(recursive: true, followLinks: false)) {
            if (e is File && audioExtensions.contains(p.extension(e.path).toLowerCase())) files.add(e.path);
          }
        } catch (_) {}
      }
      final known = await _db.trackIds();
      // Re-read tracks stored with garbled tags by older versions.
      final garbled = (await _db.tracks())
          .where((t) => [t.title, t.artist, t.album].any((s) => fixTagText(s) != s))
          .map((t) => t.id)
          .toSet();
      final fresh = files.where((f) => !known.contains(f) || garbled.contains(f)).toList();
      if (removeMissing) {
        final local = (await _db.tracks()).where((t) => t.source == TrackSource.local && !File(t.uri).existsSync());
        await _db.deleteTracks(local.map((t) => t.id));
      }
      final artDir = await _artDir();
      var done = 0;
      const batchSize = 40;
      for (var i = 0; i < fresh.length; i += batchSize) {
        final chunk = fresh.sublist(i, (i + batchSize).clamp(0, fresh.length));
        final maps = await Isolate.run(() => _readBatch(chunk, artDir, TrackSource.local));
        await _db.upsertTracks(maps.map(Track.fromMap).toList());
        done += chunk.length;
        _progress.add(ScanProgress(done, fresh.length, true));
      }
      return fresh.length;
    } finally {
      _running = false;
      _progress.add(ScanProgress.idle);
    }
  }

  /// Import a single file (e.g. a finished download) into the library.
  Future<Track?> importFile(String path, {String source = TrackSource.download}) async {
    final artDir = await _artDir();
    final maps = await Isolate.run(() => _readBatch([path], artDir, source));
    if (maps.isEmpty) return null;
    final t = Track.fromMap(maps.first);
    await _db.upsertTracks([t]);
    return t;
  }
}

/// Many taggers write UTF-8 text into ID3 frames marked as ISO-8859-1, which
/// then decodes to mojibake like "è´æ²¢". Re-decode such strings as UTF-8.
String fixTagText(String s) {
  final t = s.replaceAll('\u0000', '').trim();
  if (t.isEmpty || t.codeUnits.every((c) => c < 0x80) || t.codeUnits.any((c) => c > 0xFF)) return t;
  try {
    return utf8.decode(latin1.encode(t));
  } catch (_) {
    return t;
  }
}

List<Map<String, Object?>> _readBatch(List<String> paths, String artDir, String source) {
  final out = <Map<String, Object?>>[];
  for (final path in paths) {
    final file = File(path);
    String title = p.basenameWithoutExtension(path);
    String artist = '未知演出者';
    String album = '未知專輯';
    int? duration;
    int? trackNo;
    String? art;
    try {
      final meta = readMetadata(file, getImage: true);
      final mTitle = fixTagText(meta.title ?? '');
      final mArtist = fixTagText(meta.artist ?? '');
      final mAlbum = fixTagText(meta.album ?? '');
      if (mTitle.isNotEmpty) title = mTitle;
      if (mArtist.isNotEmpty) artist = mArtist;
      if (mAlbum.isNotEmpty) album = mAlbum;
      duration = meta.duration?.inMilliseconds;
      trackNo = meta.trackNumber;
      if (meta.pictures.isNotEmpty) {
        final pic = meta.pictures.first;
        final key = md5.convert(utf8.encode('$artist|$album|${album == '未知專輯' ? path : ''}')).toString();
        final ext = pic.mimetype.contains('png') ? 'png' : 'jpg';
        final artFile = File(p.join(artDir, '$key.$ext'));
        if (!artFile.existsSync()) artFile.writeAsBytesSync(pic.bytes);
        art = artFile.path;
      }
    } catch (_) {
      // Unreadable tags: keep the file with filename-based info.
    }
    if (art == null) {
      for (final name in ['cover.jpg', 'folder.jpg', 'Cover.jpg', 'Folder.jpg', 'cover.png']) {
        final f = File(p.join(p.dirname(path), name));
        if (f.existsSync()) {
          art = f.path;
          break;
        }
      }
    }
    out.add(Track(
      id: path,
      uri: path,
      title: title,
      artist: artist,
      album: album,
      durationMs: duration,
      art: art,
      source: source,
      trackNo: trackNo,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    ).toMap());
  }
  return out;
}
