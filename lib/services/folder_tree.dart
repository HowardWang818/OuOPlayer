import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/models/track.dart';

/// A folder inside a music folder, as the library sees it.
class SubFolder {
  const SubFolder(this.path, this.name, this.count, this.art);
  final String path;
  final String name;

  /// Songs in it and everything below it.
  final int count;

  /// A cover from one of its songs.
  final String? art;
}

/// 資料夾瀏覽: built from the library (not the disk), so only folders with
/// songs show up and nothing outside the music / download folders.
class FolderTree {
  FolderTree(Iterable<Track> tracks, {p.Context? context}) : _p = context ?? p.context {
    _tracks = [
      for (final t in tracks)
        if (t.uri.isNotEmpty && !t.uri.startsWith('http') && t.source != TrackSource.missing && t.source != TrackSource.podcast && t.source != TrackSource.preview) t,
    ];
  }

  final p.Context _p;
  late final List<Track> _tracks;

  /// The folders to start from: the music folders and the download folder,
  /// leaving out any that lies inside another one.
  List<String> roots(Iterable<String> folders) {
    final all = {for (final f in folders) if (f.trim().isNotEmpty) _p.normalize(f)}.toList();
    return [
      for (final f in all)
        if (!all.any((o) => o != f && _p.isWithin(o, f))) f,
    ];
  }

  /// How many songs are in [folder] and below it.
  int countIn(String folder) => _tracks.where((t) => _p.isWithin(folder, t.uri)).length;

  /// The folders directly inside [folder] on disk (hidden ones left out).
  static List<String> diskFolders(String folder) {
    try {
      return [
        for (final e in Directory(folder).listSync(followLinks: false))
          if (e is Directory && !p.basename(e.path).startsWith('.')) p.basename(e.path),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Every song in [folder] and below it, folder by folder.
  List<Track> everything(String folder) {
    final l = list(folder);
    return [...l.songs, for (final f in l.folders) ...everything(f.path)];
  }

  /// What is directly inside [folder]: its sub-folders (A–Z) and its songs.
  /// [disk] adds folders on disk with no songs yet (e.g. just created).
  ({List<SubFolder> folders, List<Track> songs}) list(String folder, {Iterable<String> disk = const []}) {
    final songs = <Track>[];
    final subs = <String, List<Track>>{};
    for (final t in _tracks) {
      if (!_p.isWithin(folder, t.uri)) continue;
      final parts = _p.split(_p.relative(t.uri, from: folder));
      if (parts.length == 1) {
        songs.add(t);
      } else {
        subs.putIfAbsent(parts.first, () => []).add(t);
      }
    }
    for (final d in disk) {
      subs.putIfAbsent(d, () => []);
    }
    final names = subs.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    songs.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return (
      folders: [
        for (final n in names)
          SubFolder(_p.join(folder, n), n, subs[n]!.length, subs[n]!.where((t) => t.art != null).firstOrNull?.art),
      ],
      songs: songs,
    );
  }
}
