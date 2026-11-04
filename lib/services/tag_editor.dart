import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ogg_tags.dart';

/// New song details from 編輯資訊; [cover] null keeps the current one.
class TagEdit {
  const TagEdit({required this.title, required this.artist, required this.album, this.cover, this.coverMime = 'image/jpeg'});
  final String title;
  final String artist;
  final String album;
  final Uint8List? cover;
  final String coverMime;
}

/// Formats whose tags can be written (MP3, MP4/M4A, FLAC, WAV; Opus and Ogg
/// Vorbis since v1.15.0, with [OggTags]). Others (e.g. WebM) are only changed
/// inside OuOPlayer.
const writableTagExtensions = {'.mp3', '.m4a', '.mp4', '.flac', '.wav', '.opus', '.ogg', '.oga'};

bool _isOgg(String path) => const {'.opus', '.ogg', '.oga'}.contains(p.extension(path).toLowerCase());

bool canWriteTags(String path) => writableTagExtensions.contains(p.extension(path).toLowerCase());

enum TagWriteResult { written, declined }

/// Writes [edit] into the file: edits a copy first and checks it, then puts
/// it in place (Android asks first for files OuOPlayer didn't create), so a
/// failed write never leaves a broken file behind.
Future<TagWriteResult> writeTags(String path, TagEdit edit) async {
  final temp = await _edited(path, edit);
  try {
    if (Platform.isAndroid) {
      try {
        final done = await const MethodChannel('ouo/trash').invokeMethod<bool>('overwrite', {'path': path, 'temp': temp.path});
        return done == true ? TagWriteResult.written : TagWriteResult.declined;
      } on PlatformException catch (e) {
        throw e.message ?? '寫入失敗';
      }
    }
    await temp.copy(path);
    return TagWriteResult.written;
  } finally {
    await _drop(temp);
  }
}

/// Like [writeTags], but never asks: false when Android would have to
/// (a file another app, or an earlier install, made). For sync.
Future<bool> writeTagsQuietly(String path, TagEdit edit) async {
  final temp = await _edited(path, edit);
  try {
    if (Platform.isAndroid) {
      return await const MethodChannel('ouo/trash').invokeMethod<bool>('overwrite', {'path': path, 'temp': temp.path, 'direct': true}) == true;
    }
    await temp.copy(path);
    return true;
  } finally {
    await _drop(temp);
  }
}

/// Writes several files at once: Android asks once for all of them. Songs
/// whose copy fails the check are skipped. Returns the paths written.
Future<List<String>> writeTagsMany(Map<String, TagEdit> edits) async {
  final temps = <String, File>{};
  try {
    for (final e in edits.entries) {
      try {
        temps[e.key] = await _edited(e.key, e.value);
      } catch (_) {}
    }
    if (temps.isEmpty) return const [];
    if (Platform.isAndroid) {
      final done = await const MethodChannel('ouo/trash').invokeMethod<bool>('overwrite', {
        'items': [for (final e in temps.entries) {'path': e.key, 'temp': e.value.path}],
      });
      return done == true ? temps.keys.toList() : const [];
    }
    final written = <String>[];
    for (final e in temps.entries) {
      try {
        await e.value.copy(e.key);
        written.add(e.key);
      } catch (_) {}
    }
    return written;
  } finally {
    for (final t in temps.values) {
      await _drop(t);
    }
  }
}

/// A copy of [path] with [edit] in it, read back and checked.
Future<File> _edited(String path, TagEdit edit) async {
  final tmpDir = await getTemporaryDirectory();
  final temp = File(p.join(tmpDir.path, 'tag_${DateTime.now().microsecondsSinceEpoch}${p.extension(path)}'));
  await File(path).copy(temp.path);
  try {
    final ok = await Isolate.run(() {
      final f = File(temp.path);
      if (_isOgg(path)) {
        f.writeAsBytesSync(OggTags.write(f.readAsBytesSync(),
            title: edit.title, artist: edit.artist, album: edit.album, cover: edit.cover, coverMime: edit.coverMime));
      } else {
        updateMetadata(f, (m) {
          m.setTitle(edit.title);
          m.setArtist(edit.artist);
          m.setAlbum(edit.album);
          if (edit.cover != null) m.setPictures([Picture(edit.cover!, edit.coverMime, PictureType.coverFront)]);
        });
      }
      final check = readMetadata(f);
      return check.title == edit.title && check.artist == edit.artist;
    });
    if (!ok) throw '寫入後讀回的資訊不一致，檔案沒有被修改';
    return temp;
  } catch (_) {
    await _drop(temp);
    rethrow;
  }
}

Future<void> _drop(File f) async {
  try {
    await f.delete();
  } catch (_) {}
}
