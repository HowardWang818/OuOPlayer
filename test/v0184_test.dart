import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/backup.dart';
import 'package:ouoplayer/services/library_scanner.dart';

import 'v0120_test.dart' as v0120;

Track song(String path, String title) => Track(id: path, uri: path, title: title, artist: 'A', source: TrackSource.local);

void main() {
  test('restoring only some parts leaves the rest as it was', () async {
    final src = await v0120.openDb();
    final a = song('/m/a.mp3', 'a');
    await src.db.insert('tracks', a.toMap());
    final pl = await src.createPlaylist('From backup');
    await src.addToPlaylist(pl, [a]);
    await src.db.insert('favorites', {'track_id': a.id, 'added_at': 1});
    await src.setSetting('theme', 'light');
    final backup = jsonDecode(jsonEncode(await buildBackup(src))) as Map<String, Object?>;

    final dst = await v0120.openDb();
    final b = song('/m/b.mp3', 'b');
    for (final t in [a, b]) {
      await dst.db.insert('tracks', t.toMap());
    }
    final mine = await dst.createPlaylist('Mine');
    await dst.addToPlaylist(mine, [b]);
    await dst.db.insert('favorites', {'track_id': b.id, 'added_at': 2});
    await dst.setSetting('theme', 'dark');
    final covers = await Directory.systemTemp.createTemp('ouo_covers');
    addTearDown(() => covers.delete(recursive: true));

    // Settings only: like importing a settings file.
    await restoreBackup(dst, LibraryScanner(dst), backup, coverDir: covers, parts: {RestorePart.settings});
    expect((await dst.allSettings())['theme'], 'light');
    expect([for (final p in await dst.playlists()) p.name], ['Mine']);
    expect(await dst.favoriteIds(), {b.id});

    // Likes only.
    await restoreBackup(dst, LibraryScanner(dst), backup, coverDir: covers, parts: {RestorePart.likes});
    expect(await dst.favoriteIds(), {a.id});
    expect([for (final p in await dst.playlists()) p.name], ['Mine']);
  });
}
