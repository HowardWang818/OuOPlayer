import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/folder_ops.dart';
import 'package:ouoplayer/services/folder_tree.dart';
import 'package:path/path.dart' as p;

import 'v0120_test.dart' as v0120;

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('ouo_folders'));
  tearDown(() => root.delete(recursive: true));

  Future<Track> file(String rel) async {
    final f = File(p.join(root.path, rel));
    await f.parent.create(recursive: true);
    await f.writeAsString(rel);
    return Track(id: f.path, uri: f.path, title: p.basenameWithoutExtension(rel), source: TrackSource.local);
  }

  test('folder names', () {
    expect(folderNameError('Anime'), isNull);
    expect(folderNameError('  '), isNotNull);
    expect(folderNameError('a/b'), isNotNull);
    expect(folderNameError('what?'), isNotNull);
  });

  test('a moved song keeps its playlists, like, plays and listening log', () async {
    final db = await v0120.openDb();
    final a = await file('Music/a.mp3');
    await db.db.insert('tracks', a.toMap());
    final pl = await db.createPlaylist('list');
    await db.addToPlaylist(pl, [a]);
    await db.setFavorite(a, true);
    await db.db.insert('plays', {'track_id': a.id, 'count': 3, 'last_played': 1});
    await db.db.insert('listening_log', {'track_id': a.id, 'played_at': 1, 'listened_ms': 1000});

    final dest = await FolderOps(db).create(p.join(root.path, 'Music'), 'Anime');
    final report = await FolderOps(db).moveTracks([a], dest);
    final to = p.join(dest, 'a.mp3');
    expect(report.failed, 0);
    expect(report.moved[a.id]!.uri, to);
    expect(File(to).existsSync() && !File(a.uri).existsSync(), isTrue);
    expect((await db.playlistTracks(pl)).single.id, to);
    expect((await db.favoriteIds()), {to});
    expect((await db.db.query('plays')).single['track_id'], to);
    expect((await db.db.query('listening_log')).single['track_id'], to);
    expect(await db.db.query('tracks', where: 'id = ?', whereArgs: [a.id]), isEmpty);
  });

  test('a same-name file gets 「(2)」 and the .lrc goes along', () async {
    final db = await v0120.openDb();
    final a = await file('Music/x/song.mp3');
    await File(p.join(root.path, 'Music/x/song.lrc')).writeAsString('[00:01]hi');
    await file('Music/y/song.mp3');
    await db.db.insert('tracks', a.toMap());
    final report = await FolderOps(db).moveTracks([a], p.join(root.path, 'Music', 'y'));
    expect(p.basename(report.moved[a.id]!.uri), 'song (2).mp3');
    expect(File(p.join(root.path, 'Music/y/song (2).lrc')).existsSync(), isTrue);
  });

  test('renaming a folder moves every song in it and below', () async {
    final db = await v0120.openDb();
    final a = await file('Music/Old/a.mp3');
    final b = await file('Music/Old/Deep/b.mp3');
    for (final t in [a, b]) {
      await db.db.insert('tracks', t.toMap());
    }
    await db.setFavorite(b, true);
    final folder = p.join(root.path, 'Music', 'Old');
    final report = await FolderOps(db).renameFolder(folder, 'New', [a, b]);
    final newB = p.join(root.path, 'Music', 'New', 'Deep', 'b.mp3');
    expect(report.moved[b.id]!.uri, newB);
    expect(File(newB).existsSync(), isTrue);
    expect(Directory(folder).existsSync(), isFalse);
    expect(await db.favoriteIds(), {newB});
    expect(() => FolderOps(db).renameFolder(p.join(root.path, 'Music', 'New'), 'a/b', const []), throwsA(isA<String>()));
  });

  test('empty folders go, folders with other files stay', () async {
    await Directory(p.join(root.path, 'E', 'inner')).create(recursive: true);
    expect(await FolderOps.removeEmptyDirs(p.join(root.path, 'E')), isTrue);
    await file('F/notes.txt');
    expect(await FolderOps.removeEmptyDirs(p.join(root.path, 'F')), isFalse);
  });

  test('new empty folders show up when browsing', () async {
    final a = await file('Music/a.mp3');
    await Directory(p.join(root.path, 'Music', 'Empty')).create();
    final music = p.join(root.path, 'Music');
    final l = FolderTree([a]).list(music, disk: FolderTree.diskFolders(music));
    expect([for (final f in l.folders) (f.name, f.count)], [('Empty', 0)]);
  });
}
