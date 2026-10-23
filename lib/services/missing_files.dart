import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/models/track.dart';

/// Library songs (local or downloaded) whose file is gone.
///
/// Songs under a music folder that can't be read right now (storage
/// permission taken away, SD card removed) are left out: their files may
/// only be out of reach, and removing them would empty the library.
List<Track> findMissingTracks(
  Iterable<Track> tracks,
  List<String> roots, {
  bool Function(String path)? fileExists,
  bool Function(String dir)? dirReadable,
}) {
  final exists = fileExists ?? (f) => File(f).existsSync();
  final readable = dirReadable ?? _dirReadable;
  final rootOk = <String, bool>{};
  bool reachable(String path) {
    for (final r in roots) {
      if (r.isEmpty || !p.isWithin(r, path)) continue;
      return rootOk.putIfAbsent(r, () => readable(r));
    }
    return true;
  }

  return [
    for (final t in tracks)
      if ((t.source == TrackSource.local || t.source == TrackSource.download) && !exists(t.uri) && reachable(t.uri)) t,
  ];
}

bool _dirReadable(String dir) {
  try {
    final d = Directory(dir);
    if (!d.existsSync()) return false;
    d.listSync(followLinks: false);
    return true;
  } catch (_) {
    return false;
  }
}
