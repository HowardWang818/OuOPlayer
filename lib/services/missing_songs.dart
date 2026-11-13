import 'dart:async';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../data/db/database.dart';
import '../data/models/track.dart';
import 'song_matcher.dart';
import 'sync2/merge.dart' show songKey;

/// A song that filled in a missing playlist entry.
class FilledSong {
  const FilledSong(this.track, this.playlists);
  final Track track;

  /// Names of the playlists it was put back into.
  final List<String> playlists;
}

/// Playlist songs that aren't on the device yet (e.g. from a Spotify import)
/// are kept as greyed placeholders ([TrackSource.missing]) at their place.
/// When a song enters the library later — download, scan, import — the
/// placeholders it surely matches are swapped for it.
class MissingSongs {
  MissingSongs._();

  static final _filled = StreamController<List<FilledSong>>.broadcast();

  /// Songs that just filled placeholders (the app shows a message).
  static Stream<List<FilledSong>> get filled => _filled.stream;

  static final _random = Random();

  /// A new placeholder for a song not found on the device.
  static Future<Track> create(AppDatabase app, String title, String artist, {String album = '未知專輯', int? durationMs}) async {
    final id = 'missing:${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 20)}';
    final t = Track(
      id: id,
      uri: '',
      title: title,
      artist: artist.isEmpty ? '未知演出者' : artist,
      album: album.isEmpty ? '未知專輯' : album,
      durationMs: durationMs,
      source: TrackSource.missing,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await app.db.insert('tracks', t.toMap(), conflictAlgorithm: ConflictAlgorithm.ignore);
    return t;
  }

  /// 刪除檔案 (1.20.5): the songs keep their places in playlists and likes,
  /// greyed, so they can be downloaded or sent again. Not a playlist action:
  /// synced devices keep the songs too.
  /// Its plays too: on the greyed song, or (in no playlist or likes) kept
  /// under its names, and they go to the song downloaded again.
  static Future<void> keepPlaces(AppDatabase app, List<Track> songs) async {
    for (final t in songs) {
      final listed = await app.db.query('playlist_tracks', columns: ['track_id'], where: 'track_id = ?', whereArgs: [t.id], limit: 1);
      final liked = await app.db.query('favorites', columns: ['track_id'], where: 'track_id = ?', whereArgs: [t.id], limit: 1);
      if (listed.isEmpty && liked.isEmpty) {
        final played = await app.db.query('listening_log', columns: ['id'], where: 'track_id = ?', whereArgs: [t.id], limit: 1);
        final counted = await app.db.query('plays', columns: ['track_id'], where: 'track_id = ?', whereArgs: [t.id], limit: 1);
        if (played.isEmpty && counted.isEmpty) continue;
        final id = _byName(t);
        await app.db.rawInsert('INSERT OR IGNORE INTO remote_songs(id, title, artist, album, duration_ms) VALUES(?, ?, ?, ?, ?)',
            [id, t.title, t.artist, t.album, t.durationMs]);
        await _movePlays(app, t.id, id);
        continue;
      }
      final hole = await create(app, t.title, t.artist, album: t.album, durationMs: t.durationMs);
      await app.db.update('playlist_tracks', {'track_id': hole.id}, where: 'track_id = ?', whereArgs: [t.id]);
      await app.db.update('favorites', {'track_id': hole.id}, where: 'track_id = ?', whereArgs: [t.id]);
      await _movePlays(app, t.id, hole.id);
    }
  }

  /// Plays kept under a song's names (deleted here, or only played on
  /// another device): the id they wait under.
  static String _byName(Track t) => 'remote:${songKey(t.title, t.artist)}';

  /// A song just came into the library: plays waiting under its names are its.
  static Future<void> adoptPlays(AppDatabase app, Track song) async {
    if (song.source != TrackSource.local && song.source != TrackSource.download) return;
    await _movePlays(app, _byName(song), song.id);
  }

  /// Play counts, recently played and the listening log of [from] go to [to].
  static Future<void> _movePlays(AppDatabase app, String from, String to) async {
    await app.db.update('history', {'track_id': to}, where: 'track_id = ?', whereArgs: [from]);
    await app.db.update('listening_log', {'track_id': to}, where: 'track_id = ?', whereArgs: [from]);
    final p = (await app.db.query('plays', where: 'track_id = ?', whereArgs: [from])).firstOrNull;
    if (p == null) return;
    await app.db.rawInsert('INSERT OR IGNORE INTO plays(track_id, count, last_played) VALUES(?, 0, NULL)', [to]);
    await app.db.rawUpdate('UPDATE plays SET count = count + ?, last_played = MAX(COALESCE(last_played, 0), ?) WHERE track_id = ?',
        [p['count'], p['last_played'] ?? 0, to]);
    await app.db.delete('plays', where: 'track_id = ?', whereArgs: [from]);
  }

  static Future<List<Track>> all(AppDatabase app) async {
    final rows = await app.db.query('tracks', where: 'source = ?', whereArgs: [TrackSource.missing], orderBy: 'added_at');
    return rows.map(Track.fromMap).toList();
  }

  /// Puts [newTracks] in place of the placeholders they surely match, in
  /// every playlist (and likes). Returns what was filled.
  static Future<List<FilledSong>> fill(AppDatabase app, Iterable<Track> newTracks) async {
    final songs = newTracks.where((t) => t.source == TrackSource.local || t.source == TrackSource.download).toList();
    if (songs.isEmpty) return const [];
    final missing = await all(app);
    if (missing.isEmpty) return const [];
    final used = <String>{};
    final done = <FilledSong>[];
    for (final song in songs) {
      // One song can fill the same missing song in several playlists, but
      // each placeholder only once.
      final key = SongKey(song.title, song.artist, durationMs: song.durationMs);
      final matches = [
        for (final m in missing)
          if (!used.contains(m.id) && SongMatcher.compare(key, SongKey(m.title, m.artist, durationMs: m.durationMs)).level == MatchLevel.sure) m,
      ];
      if (matches.isEmpty) continue;
      final names = <String>[];
      for (final m in matches) {
        used.add(m.id);
        names.addAll(await _swap(app, m.id, song));
      }
      if (matches.isNotEmpty) done.add(FilledSong(song, names.toSet().toList()));
    }
    if (done.isNotEmpty) {
      app.notifyChanged();
      _filled.add(done);
    }
    return done;
  }

  /// A song sent from another device: it takes the place of every
  /// placeholder with its exact title and artist (the names that device
  /// shows), then of any it surely matches.
  static Future<void> fillExact(AppDatabase app, Track song) async {
    final key = '${foldText(song.title)}|${foldText(song.artist)}';
    var swapped = <String>[];
    for (final m in await all(app)) {
      if ('${foldText(m.title)}|${foldText(m.artist)}' == key) swapped.addAll(await _swap(app, m.id, song));
    }
    if (swapped.isNotEmpty) {
      app.notifyChanged();
      _filled.add([FilledSong(song, swapped.toSet().toList())]);
    }
    await fill(app, [song]);
  }

  /// Songs sent before v1.8.1 kept the file's own names, so some missed their
  /// playlists: a placeholder is filled by a downloaded song of the same
  /// length (within 1 s) whose title or artist is the same.
  static Future<List<FilledSong>> fillLoose(AppDatabase app) async {
    final missing = await all(app);
    if (missing.isEmpty) return const [];
    final songs = (await app.tracks()).where((t) => t.source == TrackSource.download && t.durationMs != null).toList();
    final usedSongs = <String>{};
    final done = <FilledSong>[];
    for (final m in missing) {
      final ms = m.durationMs;
      if (ms == null) continue;
      final title = foldText(SongMatcher.searchTitle(m.title, m.artist));
      final song = songs.where((t) {
        if (usedSongs.contains(t.id) || (t.durationMs! - ms).abs() > 1000) return false;
        return foldText(SongMatcher.searchTitle(t.title, t.artist)) == title ||
            SongMatcher.sameArtist(SongKey(t.title, t.artist), SongKey(m.title, m.artist));
      }).firstOrNull;
      if (song == null) continue;
      usedSongs.add(song.id);
      done.add(FilledSong(song, await _swap(app, m.id, song)));
    }
    if (done.isNotEmpty) {
      app.notifyChanged();
      _filled.add(done);
    }
    return done;
  }

  /// Puts [song] wherever the placeholder [missingId] is (playlists, likes)
  /// and drops the placeholder. Returns the list names it went into.
  static Future<List<String>> _swap(AppDatabase app, String missingId, Track song) async {
    final names = <String>[];
    final rows = await app.db.rawQuery(
        'SELECT DISTINCT p.name AS name FROM playlist_tracks pt JOIN playlists p ON p.id = pt.playlist_id WHERE pt.track_id = ?', [missingId]);
    names.addAll(rows.map((r) => r['name'] as String));
    await app.db.update('playlist_tracks', {'track_id': song.id}, where: 'track_id = ?', whereArgs: [missingId]);
    final liked = await app.db.query('favorites', where: 'track_id = ?', whereArgs: [missingId]);
    if (liked.isNotEmpty) {
      await app.db.delete('favorites', where: 'track_id = ?', whereArgs: [missingId]);
      await app.db.insert('favorites', {'track_id': song.id, 'added_at': liked.first['added_at']}, conflictAlgorithm: ConflictAlgorithm.ignore);
      names.add('已按讚的歌曲');
    }
    await _movePlays(app, missingId, song.id);
    await app.db.delete('tracks', where: 'id = ?', whereArgs: [missingId]);
    return names;
  }

  /// 從音樂庫選擇這首歌: the user says which library song a placeholder is.
  static Future<List<String>> replace(AppDatabase app, String missingId, Track song) async {
    final names = await _swap(app, missingId, song);
    app.notifyChanged();
    return names;
  }

  /// Library songs ordered by how likely they are [missing] (best first).
  static List<Track> rank(Track missing, Iterable<Track> library) {
    final key = SongKey(missing.title, missing.artist, durationMs: missing.durationMs);
    final scored = [
      for (final t in library)
        if (t.source != TrackSource.missing) (t, SongMatcher.compare(key, SongKey(t.title, t.artist, durationMs: t.durationMs))),
    ];
    scored.sort((a, b) {
      final l = b.$2.level.index.compareTo(a.$2.level.index);
      return l != 0 ? l : b.$2.score.compareTo(a.$2.score);
    });
    return [for (final (t, _) in scored) t];
  }

  /// Removes a placeholder from everywhere (after the user confirmed).
  static Future<void> remove(AppDatabase app, String id) => app.deleteTracks([id]);
}
