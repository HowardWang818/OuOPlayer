import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/db/database.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/car_browser.dart';
import 'package:ouoplayer/services/listening_stats.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<AppDatabase> openDb() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath, options: OpenDatabaseOptions(singleInstance: false));
  await db.execute('CREATE TABLE tracks(id TEXT PRIMARY KEY, uri TEXT NOT NULL, title TEXT NOT NULL, artist TEXT, album TEXT, '
      'duration_ms INTEGER, art TEXT, source TEXT, track_no INTEGER, added_at INTEGER)');
  await db.execute('CREATE TABLE playlists(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, created_at INTEGER)');
  await db.execute('CREATE TABLE playlist_tracks(playlist_id INTEGER, track_id TEXT, position INTEGER)');
  await db.execute('CREATE TABLE favorites(track_id TEXT PRIMARY KEY, added_at INTEGER)');
  await db.execute('CREATE TABLE history(track_id TEXT, played_at INTEGER)');
  await db.execute('CREATE TABLE podcasts(feed_url TEXT PRIMARY KEY, title TEXT, author TEXT, image TEXT, added_at INTEGER)');
  await db.execute('CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT)');
  await AppDatabase.migrate(db, 1, AppDatabase.schemaVersion);
  return AppDatabase.wrap(db);
}

Track song(String id, String artist, {int? ms, String source = TrackSource.download}) =>
    Track(id: id, uri: id, title: id, artist: artist, album: 'al', durationMs: ms, source: source);

ListeningEntry play(String id, DateTime at, int seconds, {String source = TrackSource.download, bool estimated = false}) =>
    ListeningEntry(trackId: id, playedAt: at, listened: Duration(seconds: seconds), source: source, estimated: estimated);

void main() {
  test('upgrading to v6 brings the old history into the log as estimates', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath, options: OpenDatabaseOptions(singleInstance: false));
    await db.execute('CREATE TABLE tracks(id TEXT PRIMARY KEY, uri TEXT, title TEXT, duration_ms INTEGER, source TEXT)');
    await db.execute('CREATE TABLE history(track_id TEXT, played_at INTEGER)');
    await db.insert('tracks', {'id': 'a', 'uri': 'a', 'title': 'a', 'duration_ms': 200000, 'source': 'download'});
    await db.insert('history', {'track_id': 'a', 'played_at': 10});
    await db.insert('history', {'track_id': 'gone', 'played_at': 20});
    await AppDatabase.migrate(db, 5, 6);
    final rows = await db.query('listening_log', orderBy: 'played_at');
    expect(rows.map((r) => (r['track_id'], r['listened_ms'], r['estimated'])), [('a', 200000, 1), ('gone', 0, 1)]);
    await db.close();
  });

  test('a play is logged and its listening time updated', () async {
    final db = await openDb();
    final at = DateTime(2026, 10, 24, 9);
    final id = await db.startListening(song('a', 'A'), at);
    await db.updateListening(id, const Duration(seconds: 95));
    final log = await db.listening(DateTime(2026, 10, 24), DateTime(2026, 10, 25));
    expect(log.single.listened, const Duration(seconds: 95));
    expect(log.single.playedAt, at);
    expect(await db.listening(DateTime(2026, 10, 25), DateTime(2026, 10, 26)), isEmpty);
  });

  group('statistics', () {
    final lib = {
      'a': song('a', 'YOASOBI'),
      'b': song('b', 'YOASOBI'),
      'c': song('c', 'natori'),
    };
    final day = DateTime(2026, 10, 20);
    final log = [
      play('a', day.add(const Duration(hours: 8)), 200),
      play('a', day.add(const Duration(hours: 21)), 180),
      play('b', day.add(const Duration(days: 1, hours: 22)), 100),
      play('c', day.add(const Duration(days: 1, hours: 2)), 240, estimated: true),
      play('b', day.add(const Duration(days: 2)), 3), // skipped: not a play
      play('ep', day, 1800, source: TrackSource.podcast),
      play('gone', day.add(const Duration(hours: 9)), 60),
    ];
    final s = ListeningStats.compute(log, lib);

    test('totals keep music and podcasts apart and drop skips', () {
      expect(s.music, const Duration(seconds: 200 + 180 + 100 + 240 + 60));
      expect(s.podcasts, const Duration(minutes: 30));
      expect(s.plays, 5);
      expect(s.distinctSongs, 4);
      expect(s.hasEstimates, isTrue);
    });

    test('top songs and artists', () {
      expect(s.topTracks.map((t) => (t.track.id, t.plays)), [('a', 2), ('c', 1), ('b', 1)]);
      expect(s.topArtists.map((a) => (a.name, a.plays)), [('YOASOBI', 3), ('natori', 1)]);
    });

    test('days, months and times of day', () {
      expect(s.daily[day], const Duration(seconds: 440));
      expect(s.monthly.keys, [10]);
      expect(s.busiestMonth, 10);
      expect(s.dayParts[DayPart.evening], const Duration(seconds: 280));
      expect(s.favouriteDayPart, DayPart.evening);
    });

    test('periods', () {
      final (from, to) = StatsPeriod.week.range(DateTime(2026, 10, 24, 15)); // a Saturday
      expect((from, to), (DateTime(2026, 10, 19), DateTime(2026, 10, 25)));
      expect(StatsPeriod.month.range(DateTime(2026, 12, 5)), (DateTime(2026, 12), DateTime(2027, 1)));
      expect(formatListening(const Duration(hours: 32, minutes: 15)), '32 小時 15 分');
      expect(formatListening(const Duration(minutes: 7)), '7 分鐘');
    });
  });

  group('Android Auto', () {
    test('folders, lists and playing from a list', () async {
      final db = await openDb();
      for (final t in [song('a', 'YOASOBI'), song('b', 'YOASOBI'), song('c', 'natori')]) {
        await db.db.insert('tracks', t.toMap());
      }
      final pl = await db.createPlaylist('通勤');
      await db.addToPlaylist(pl, [song('c', 'natori'), song('a', 'YOASOBI')]);
      await db.db.insert('favorites', {'track_id': 'b', 'added_at': 1});
      final car = CarBrowser(db, episodes: (url) async => [song('ep1', 'show', source: TrackSource.podcast)]);

      final root = await car.children(CarBrowser.root);
      // At most four tabs in Android Auto.
      expect(root.map((m) => m.title), ['首頁', '最近播放', '音樂庫', 'Podcast']);
      // Tab icons are plain vectors the car tints.
      expect(root.first.artUri.toString(), 'android.resource://com.ouo.ouoplayer/drawable/car_home');
      expect(root.every((m) => m.playable == false), isTrue);

      final lists = await car.children(CarBrowser.library);
      expect(lists.map((m) => m.id),
          [CarBrowser.liked, 'pl:$pl', for (final s in SmartList.values) 'smart:${s.name}', CarBrowser.albums, CarBrowser.artists]);
      expect(lists.map((m) => m.extras?[CarBrowser.groupTitle]).toSet(), {'播放清單', '智慧播放清單', '瀏覽'});
      // Song lists open as lists, the album and artist pages as grids.
      expect(lists.first.extras?[CarBrowser.browsableHint], CarBrowser.styleList);
      expect(lists.last.extras?[CarBrowser.browsableHint], CarBrowser.styleGrid);
      final home = await car.children(CarBrowser.home);
      expect(home.first.title, '已按讚的歌曲');
      expect(home.any((m) => m.id == 'pl:$pl'), isTrue);
      // No cover of its own: an icon served by ArtProvider.
      expect(lists.first.artUri.toString(), 'content://com.ouo.ouoplayer.art/icon/favorite');

      final songs = await car.children('pl:$pl');
      expect(songs.map((m) => (m.id, m.title, m.playable)), [('pl:$pl#0', 'c', true), ('pl:$pl#1', 'a', true)]);

      final (list, index) = (await car.resolve('pl:$pl#1'))!;
      expect(list.map((t) => t.id), ['c', 'a']);
      expect(index, 1);
      expect((await car.children(CarBrowser.liked)).single.title, 'b');
      expect((await car.children('artist:natori')).single.title, 'c');
      expect((await car.children('podcast:https://x/feed')).single.title, 'ep1');
      expect((await car.search('YOASOBI')).map((m) => m.title).toSet(), {'a', 'b'});
      expect(await car.resolve('pl:$pl#9'), isNull);
      expect(await car.resolve('nonsense'), isNull);
    });
  });
}
