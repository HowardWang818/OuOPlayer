import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// New song details from 編輯資訊; [cover] null keeps the current one.
class TagEdit {
  const TagEdit({required this.title, required this.artist, required this.album, this.cover, this.coverMime = 'image/jpeg'});
  final String title;
  final String artist;
  final String album;
  final Uint8List? cover;
  final String coverMime;
}

/// Formats whose tags can be written (MP3, MP4/M4A, FLAC, WAV). Others
/// (e.g. Opus, WebM) are only changed inside OuOPlayer.
const writableTagExtensions = {'.mp3', '.m4a', '.mp4', '.flac', '.wav'};

bool canWriteTags(String path) => writableTagExtensions.contains(p.extension(path).toLowerCase());

enum TagWriteResult { written, declined }

/// Writes [edit] into the file: edits a copy first and checks it, then puts
/// it in place (Android asks first for files OuOPlayer didn't create), so a
/// failed write never leaves a broken file behind.
Future<TagWriteResult> writeTags(String path, TagEdit edit) async {
  final tmpDir = await getTemporaryDirectory();
  final temp = File(p.join(tmpDir.path, 'tag_${DateTime.now().microsecondsSinceEpoch}${p.extension(path)}'));
  await File(path).copy(temp.path);
  try {
    final ok = await Isolate.run(() {
      final f = File(temp.path);
      updateMetadata(f, (m) {
        m.setTitle(edit.title);
        m.setArtist(edit.artist);
        m.setAlbum(edit.album);
        if (edit.cover != null) m.setPictures([Picture(edit.cover!, edit.coverMime, PictureType.coverFront)]);
      });
      final check = readMetadata(f);
      return check.title == edit.title && check.artist == edit.artist;
    });
    if (!ok) throw '寫入後讀回的資訊不一致，檔案沒有被修改';
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
    try {
      await temp.delete();
    } catch (_) {}
  }
}
