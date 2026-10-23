import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/db/database.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/lyrics/lyrics_service.dart';
import 'package:ouoplayer/services/missing_files.dart';
import 'package:ouoplayer/ui/widgets/removal_summary.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('Android trash files are not songs', () {
    const dir = '/storage/emulated/0/Music/OuOPlayer';

    test('hidden files and folders', () {
      expect(isHiddenPath('$dir/.trashed-1729650000-propose.mp3'), isTrue);
      expect(isHiddenPath('$dir/.pending-1-x.m4a'), isTrue);
      expect(isHiddenPath('/storage/emulated/0/.thumbnails/a.mp3'), isTrue);
      expect(isHiddenPath('$dir/propose.mp3'), isFalse);
      expect(isHiddenPath('$dir/a.b.mp3'), isFalse);
    });

    test('trashed library entries are found', () {
      Track t(String uri, [String source = TrackSource.download]) => Track(id: uri, uri: uri, title: 'propose', source: source);
      final found = findTrashedTracks([t('$dir/propose.mp3'), t('$dir/.trashed-1-propose.mp3'), t('$dir/.trashed-2-x.mp3', TrackSource.local)]);
      expect(found.map((x) => x.uri), ['$dir/.trashed-1-propose.mp3', '$dir/.trashed-2-x.mp3']);
    });

    test('a folder already covered by another music folder', () {
      const dirs = ['/storage/emulated/0/Music', '/storage/emulated/0/Download'];
      expect(coveringFolder(dir, dirs), '/storage/emulated/0/Music');
      expect(coveringFolder('/storage/emulated/0/Music', dirs), '/storage/emulated/0/Music');
      expect(coveringFolder('/storage/emulated/0/Podcasts', dirs), isNull);
      expect(coveringFolder('/storage/emulated/0/MusicVideos', dirs), isNull);
    });
  });

  group('lyrics lookup', () {
    test('titles are cleaned for a second try', () {
      expect(LyricsService.cleanSongTitle('群青 (Official Audio)'), '群青');
      expect(LyricsService.cleanSongTitle('【MV】怪物'), '怪物');
      expect(LyricsService.cleanSongTitle('Idol feat. Someone'), 'Idol');
      expect(LyricsService.cleanSongTitle('Gajumaru Heart'), 'Gajumaru Heart');
    });

    test('synced lyrics win, then the closest length', () {
      const plainExact = LrclibResult(title: '群青', artist: 'YOASOBI', album: '', durationSec: 248, plain: 'x');
      const syncedFar = LrclibResult(title: '群青', artist: 'YOASOBI', album: '', durationSec: 300, synced: '[00:01.00]x');
      const syncedNear = LrclibResult(title: '群青', artist: 'YOASOBI', album: '', durationSec: 249, synced: '[00:01.00]x');
      expect(LyricsService.pickBest([plainExact, syncedFar, syncedNear], durationMs: 248000), same(syncedNear));
      expect(LyricsService.pickBest([plainExact], durationMs: 248000), same(plainExact));
      expect(LyricsService.pickBest([]), isNull);
    });

    test('busy server and timeouts are retried, missing pages are not', () {
      final opts = RequestOptions(path: '/');
      DioException http(int code) => DioException(requestOptions: opts, response: Response(requestOptions: opts, statusCode: code));
      expect(LyricsService.isTemporary(http(503)), isTrue);
      expect(LyricsService.isTemporary(DioException(requestOptions: opts, type: DioExceptionType.receiveTimeout)), isTrue);
      expect(LyricsService.isTemporary(http(404)), isFalse);
    });
  });

  group('delete warning lists where songs are removed from', () {
    test('one song', () {
      final lines = describeRemoval(
          const RemovalImpact(playlists: {'Liked': 2, '通勤': 1}, favorites: 1, emptyAlbums: ['propose'], emptyArtists: ['natori']),
          songs: 1,
          inQueue: 1);
      expect(lines, [
        '音樂庫',
        '播放清單：「Liked」（2 次）、「通勤」',
        '已按讚的歌曲',
        '目前的播放佇列',
        '專輯 「propose」（只剩這些歌，會一起消失）',
        '演出者 「natori」（只剩這些歌，會一起消失）',
      ]);
    });

    test('several songs, library only', () {
      expect(describeRemoval(const RemovalImpact(), songs: 3), ['音樂庫']);
      expect(describeRemoval(const RemovalImpact(playlists: {'Liked': 12}, favorites: 5), songs: 20),
          ['音樂庫', '播放清單：「Liked」（12 首）', '已按讚的歌曲（5 首）']);
    });

    test('impact comes from playlists, likes and what is left', () async {
      sqfliteFfiInit();
      final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await raw.execute('CREATE TABLE tracks(id TEXT PRIMARY KEY, uri TEXT NOT NULL, title TEXT NOT NULL, artist TEXT, album TEXT, '
          'duration_ms INTEGER, art TEXT, source TEXT, track_no INTEGER, added_at INTEGER)');
      await raw.execute('CREATE TABLE playlists(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, created_at INTEGER)');
      await raw.execute('CREATE TABLE playlist_tracks(playlist_id INTEGER, track_id TEXT, position INTEGER)');
      await raw.execute('CREATE TABLE favorites(track_id TEXT PRIMARY KEY, added_at INTEGER)');
      final db = AppDatabase.wrap(raw);
      for (final t in [
        const Track(id: 'a', uri: 'a', title: 'propose', artist: 'natori', album: 'propose'),
        const Track(id: 'b', uri: 'b', title: 'x', artist: 'YOASOBI', album: 'THE BOOK'),
        const Track(id: 'c', uri: 'c', title: 'y', artist: 'YOASOBI', album: 'THE BOOK'),
      ]) {
        await raw.insert('tracks', t.toMap());
      }
      final liked = await db.createPlaylist('Liked');
      await db.addToPlaylist(liked, [const Track(id: 'a', uri: 'a', title: 'propose'), const Track(id: 'b', uri: 'b', title: 'x')]);
      await db.addToPlaylist(liked, [const Track(id: 'a', uri: 'a', title: 'propose')], allowDuplicates: true);
      await raw.insert('favorites', {'track_id': 'a', 'added_at': 1});
      final i = await db.removalImpact(['a', 'b']);
      expect(i.playlists, {'Liked': 3});
      expect(i.favorites, 1);
      expect(i.emptyAlbums, ['propose']);
      expect(i.emptyArtists, ['natori']);
      await raw.close();
    });
  });
}
