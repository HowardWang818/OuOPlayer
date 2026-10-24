import 'dart:async';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../data/db/database.dart';
import '../data/models/track.dart';
import 'song_matcher.dart';

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
        final rows = await app.db.rawQuery(
            'SELECT DISTINCT p.name AS name FROM playlist_tracks pt JOIN playlists p ON p.id = pt.playlist_id WHERE pt.track_id = ?', [m.id]);
        names.addAll(rows.map((r) => r['name'] as String));
        await app.db.update('playlist_tracks', {'track_id': song.id}, where: 'track_id = ?', whereArgs: [m.id]);
        final liked = await app.db.query('favorites', where: 'track_id = ?', whereArgs: [m.id]);
        if (liked.isNotEmpty) {
          await app.db.delete('favorites', where: 'track_id = ?', whereArgs: [m.id]);
          await app.db.insert('favorites', {'track_id': song.id, 'added_at': liked.first['added_at']}, conflictAlgorithm: ConflictAlgorithm.ignore);
          names.add('已按讚的歌曲');
        }
        await app.db.delete('tracks', where: 'id = ?', whereArgs: [m.id]);
      }
      if (matches.isNotEmpty) done.add(FilledSong(song, names.toSet().toList()));
    }
    if (done.isNotEmpty) {
      app.notifyChanged();
      _filled.add(done);
    }
    return done;
  }

  /// Removes a placeholder from everywhere (after the user confirmed).
  static Future<void> remove(AppDatabase app, String id) => app.deleteTracks([id]);
}
