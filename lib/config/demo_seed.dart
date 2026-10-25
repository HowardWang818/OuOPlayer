import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../data/db/database.dart';
import '../data/models/track.dart';
import '../services/artist_images.dart';
import 'demo.dart';

/// Demo copy only: playlists, likes and some listening history for the
/// README screenshots, once the demo songs are in the library.
/// The made-up artists, in the order of the photos in OuOPlayerDemo/artists.
const demoArtists = ['星屑ドライブ', '紙飛機計畫', 'Luna Harbor', '霧島ネオン', '夜行列車', 'The Paper Lanterns', '白鯨合唱團', 'Asterwood'];

Future<void> seedDemo(AppDatabase db) async {
  if (!isDemo) return;
  if ((await db.allSettings())['demo_seeded'] == 'true') return;
  final tracks = await db.tracks();
  if (tracks.length < 20) return;
  final byTitle = {for (final t in tracks) t.title: t};
  List<Track> pick(List<String> titles) => [for (final n in titles) if (byTitle[n] case final t?) t];

  for (final (name, songs) in [
    ('通勤歌單', ['青信号', 'Neon Tide', '雨音シグナル', '末班車', 'Golden Static', '夜明けの周波数', 'Lighthouse']),
    ('深夜放鬆', ['ミッドナイト・ラジオ', 'Small Hours', '深藍', '城市微光', 'Paper Moon', '浮游']),
    ('夏天的歌', ['白晝之夏', '我們的海', '慢慢走', 'Saltwater', 'Wildflower Season']),
  ]) {
    if ((await db.playlists()).any((p) => p.name == name)) continue;
    final id = await db.createPlaylist(name);
    await db.addToPlaylist(id, pick(songs));
  }
  for (final t in pick(['白晝之夏', 'Neon Tide', '末班車', 'ガラスの温室', 'Small Hours', '夜明けの周波数', '深藍', 'Lighthouse'])) {
    await db.setFavorite(t, true);
  }

  // A few weeks of listening, favourites more often.
  final rnd = Random(7);
  final now = DateTime.now();
  final weights = {for (final t in tracks) t.id: 1 + rnd.nextInt(4)};
  for (final n in ['白晝之夏', 'Neon Tide', '末班車', '青信号', 'Small Hours']) {
    final t = byTitle[n];
    if (t != null) weights[t.id] = 9 + rnd.nextInt(6);
  }
  final batch = db.db.batch();
  for (final t in tracks) {
    final n = weights[t.id]!;
    var last = 0;
    for (var i = 0; i < n; i++) {
      final at = now.subtract(Duration(days: rnd.nextInt(40), hours: rnd.nextInt(14), minutes: rnd.nextInt(60))).millisecondsSinceEpoch;
      last = max(last, at);
      batch.insert('history', {'track_id': t.id, 'played_at': at});
      batch.insert('listening_log', {'track_id': t.id, 'played_at': at, 'listened_ms': t.durationMs ?? 200000, 'source': t.source, 'estimated': 0});
    }
    batch.insert('plays', {'track_id': t.id, 'count': n, 'last_played': last}, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  await batch.commit(noResult: true);

  // Artist photos (drawn silhouettes), pushed into the app's own folder
  // (Android/data/…/files/artists): shared storage images need another permission.
  final own = await getExternalStorageDirectory();
  for (final (i, name) in demoArtists.indexed) {
    final photo = File('${own?.path}/artists/$i.jpg');
    if (photo.existsSync()) await ArtistImages.setCustomFile(name, photo.path);
  }
  await db.setSetting('demo_seeded', 'true');
  db.notifyChanged();
}
