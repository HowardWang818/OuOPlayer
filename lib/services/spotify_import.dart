import 'dart:convert';

import 'package:path/path.dart' as p;

import '../data/models/track.dart';
import 'song_matcher.dart';

/// One song in a Spotify export.
class SpotifySong {
  const SpotifySong(this.title, this.artists, {this.album, this.durationMs});
  final String title;
  final List<String> artists;
  final String? album;
  final int? durationMs;

  String get label => artists.isEmpty ? title : '$title - ${artists.join(', ')}';
}

/// A playlist from a Spotify export; [liked] for Spotify's 「已按讚的歌曲」.
class SpotifyPlaylist {
  const SpotifyPlaylist(this.name, this.songs, {this.liked = false});
  final String name;
  final List<SpotifySong> songs;
  final bool liked;
}

/// Reads Spotify's own 「下載你的資料」 files (Playlist1.json…, YourLibrary.json)
/// and Exportify CSV files. Unknown files give nothing.
List<SpotifyPlaylist> parseSpotifyExport(String text, {required String fileName}) {
  final body = text.replaceFirst('﻿', '');
  if (p.extension(fileName).toLowerCase() == '.csv') {
    final pl = parseExportifyCsv(body, name: p.basenameWithoutExtension(fileName).replaceAll('_', ' '));
    return pl == null ? const [] : [pl];
  }
  final Object? json;
  try {
    json = jsonDecode(body);
  } catch (_) {
    return const [];
  }
  if (json is! Map) return const [];
  final out = <SpotifyPlaylist>[];
  final playlists = json['playlists'];
  if (playlists is List) {
    for (final pl in playlists.whereType<Map>()) {
      final songs = <SpotifySong>[];
      for (final item in (pl['items'] as List? ?? const []).whereType<Map>()) {
        final t = item['track'];
        if (t is! Map) continue; // podcast episodes, local files
        final title = (t['trackName'] as String?)?.trim() ?? '';
        if (title.isEmpty) continue;
        songs.add(SpotifySong(title, _splitArtists(t['artistName'] as String?), album: t['albumName'] as String?));
      }
      out.add(SpotifyPlaylist((pl['name'] as String?)?.trim().isNotEmpty == true ? pl['name'] as String : '未命名播放清單', songs));
    }
  }
  final liked = json['tracks'];
  if (liked is List) {
    final songs = [
      for (final t in liked.whereType<Map>())
        if (((t['track'] as String?) ?? '').trim().isNotEmpty)
          SpotifySong((t['track'] as String).trim(), _splitArtists(t['artist'] as String?), album: t['album'] as String?),
    ];
    if (songs.isNotEmpty) out.add(SpotifyPlaylist('Spotify 按讚', songs, liked: true));
  }
  return out;
}

/// An Exportify CSV: columns found by their header (names vary by version).
SpotifyPlaylist? parseExportifyCsv(String text, {required String name}) {
  final rows = parseCsv(text);
  if (rows.length < 2) return null;
  final header = [for (final h in rows.first) h.trim().toLowerCase()];
  int col(bool Function(String) test) => header.indexWhere(test);
  final title = col((h) => h == 'track name' || h == 'name' || h == 'title');
  final artist = col((h) => h.startsWith('artist name') || h == 'artist' || h == 'artists');
  final album = col((h) => h == 'album name' || h == 'album');
  final duration = col((h) => h.startsWith('duration') || h.contains('(ms)'));
  if (title < 0) return null;
  String? cell(List<String> r, int i) => i >= 0 && i < r.length ? r[i].trim() : null;
  final songs = <SpotifySong>[
    for (final r in rows.skip(1))
      if ((cell(r, title) ?? '').isNotEmpty)
        SpotifySong(cell(r, title)!, _splitArtists(cell(r, artist)),
            album: cell(r, album), durationMs: int.tryParse(cell(r, duration) ?? '')),
  ];
  return SpotifyPlaylist(name, songs);
}

/// Exportify joins several artists with 「,」 or 「;」.
List<String> _splitArtists(String? s) =>
    (s ?? '').split(RegExp(r'\s*[,;]\s*')).map((a) => a.trim()).where((a) => a.isNotEmpty).toList();

/// RFC 4180 CSV: quoted fields may hold commas, quotes ("") and newlines.
List<List<String>> parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        field.write(c);
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == ',') {
      row.add(field.toString());
      field.clear();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(field.toString());
      field.clear();
      if (row.any((f) => f.isNotEmpty)) rows.add(row);
      row = <String>[];
    } else {
      field.write(c);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    if (row.any((f) => f.isNotEmpty)) rows.add(row);
  }
  return rows;
}

/// 「群青 - Remastered 2011」「Idol (Official Audio)」→ the bare title.
String bareTitle(String title) => title
    .replaceAll(RegExp(r'[\(（\[【［].*?[\)）\]】］]'), ' ')
    .replaceAll(RegExp(r'\s[-–—]\s.*(remaster|live|version|edit|mix|mono|stereo|ver\.|bonus|demo|acoustic).*$', caseSensitive: false), '')
    .replaceAll(RegExp(r'\s(feat\.?|ft\.)\s.*$', caseSensitive: false), '')
    .trim();

/// Finds Spotify songs in the library with SongMatcher: [find] gives the
/// songs it is sure about; [match] also tells 「maybe」 ones apart, which the
/// import asks the user about. Never the same title by another artist.
class SpotifyMatcher {
  SpotifyMatcher(Iterable<Track> library)
      : _index = SongIndex(library.where((t) => t.source != TrackSource.missing), (Track t) => SongKey(t.title, t.artist, durationMs: t.durationMs));

  final SongIndex<Track> _index;

  (Track?, MatchLevel) match(SpotifySong s) {
    final (t, r) = _index.find(SongKey(s.title, s.artists.join(', '), durationMs: s.durationMs));
    return (t, r.level);
  }

  Track? find(SpotifySong s) {
    final (t, level) = match(s);
    return level == MatchLevel.sure ? t : null;
  }
}
