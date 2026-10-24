import 'dart:io';

import 'package:audio_service/audio_service.dart';

/// Where a track came from.
class TrackSource {
  static const local = 'local';
  static const url = 'url';
  static const podcast = 'podcast';
  static const download = 'download';

  /// 30-second store previews: never recorded in history or the saved queue.
  static const preview = 'preview';

  /// A playlist song that isn't on the device (e.g. from a Spotify import):
  /// shown greyed, never played, replaced when the song turns up.
  static const missing = 'missing';
}

class Track {
  final String id;
  final String uri;
  final String title;
  final String artist;
  final String album;
  final int? durationMs;
  final String? art;
  final String source;
  final int? trackNo;
  final int addedAt;

  const Track({
    required this.id,
    required this.uri,
    required this.title,
    this.artist = '未知演出者',
    this.album = '未知專輯',
    this.durationMs,
    this.art,
    this.source = TrackSource.local,
    this.trackNo,
    this.addedAt = 0,
  });

  bool get isRemote => uri.startsWith('http://') || uri.startsWith('https://');

  /// The same song after its file moved to [path] (local songs are keyed by path).
  Track movedTo(String path) => Track(
      id: path, uri: path, title: title, artist: artist, album: album, durationMs: durationMs, art: art, source: source, trackNo: trackNo, addedAt: addedAt);

  Duration? get duration => durationMs == null ? null : Duration(milliseconds: durationMs!);

  factory Track.fromUrl(String url, {String? title, String? artist, String? album, String? art, String source = TrackSource.url, int? durationMs}) {
    final name = Uri.tryParse(url)?.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? url;
    return Track(
      id: url,
      uri: url,
      title: title ?? Uri.decodeComponent(name),
      artist: artist ?? '網路串流',
      album: album ?? '網路串流',
      art: art,
      source: source,
      durationMs: durationMs,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  factory Track.fromMap(Map<String, Object?> m) => Track(
        id: m['id'] as String,
        uri: m['uri'] as String,
        title: m['title'] as String,
        artist: (m['artist'] as String?) ?? '未知演出者',
        album: (m['album'] as String?) ?? '未知專輯',
        durationMs: m['duration_ms'] as int?,
        art: m['art'] as String?,
        source: (m['source'] as String?) ?? TrackSource.local,
        trackNo: m['track_no'] as int?,
        addedAt: (m['added_at'] as int?) ?? 0,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'uri': uri,
        'title': title,
        'artist': artist,
        'album': album,
        'duration_ms': durationMs,
        'art': art,
        'source': source,
        'track_no': trackNo,
        'added_at': addedAt,
      };

  Uri? get artUri {
    final a = art;
    if (a == null || a.isEmpty) return null;
    if (a.startsWith('http')) return Uri.tryParse(a);
    return Uri.file(a);
  }

  MediaItem toMediaItem() => MediaItem(
        id: uri,
        title: title,
        artist: artist,
        album: album,
        duration: duration,
        artUri: artUri,
        extras: {'track': toMap()},
      );

  static Track fromMediaItem(MediaItem item) {
    final m = item.extras?['track'];
    if (m is Map) return Track.fromMap(m.cast<String, Object?>());
    return Track.fromUrl(item.id, title: item.title, artist: item.artist, album: item.album);
  }

  bool get fileExists => isRemote || File(uri).existsSync();
}

class Album {
  final String name;
  final String artist;
  final String? art;
  final int count;

  /// When its newest song was added (ms since epoch).
  final int added;
  const Album(this.name, this.artist, this.art, this.count, [this.added = 0]);
}

class Artist {
  final String name;
  final String? art;
  final int count;

  /// When their newest song was added (ms since epoch).
  final int added;
  const Artist(this.name, this.art, this.count, [this.added = 0]);
}

class Playlist {
  final int id;
  final String name;
  final int count;
  final String? art;

  /// Image the user picked; when null, [art] is the first song's cover.
  final String? cover;
  final int? folderId;

  /// Songs listed but not on the device (greyed placeholders), not in [count].
  final int missing;
  const Playlist(this.id, this.name, this.count, this.art, {this.cover, this.folderId, this.missing = 0});
}

/// A folder of playlists in the library (one level, no nesting).
class PlaylistFolder {
  final int id;
  final String name;
  final int count;
  final List<String> arts;
  const PlaylistFolder(this.id, this.name, this.count, this.arts);
}

/// A library entry for a music folder (Windows), or all local music when
/// [path] is null (Android's 「本地音樂」).
class LibraryFolder {
  final String? path;
  final String name;
  final int count;
  const LibraryFolder(this.path, this.name, this.count);
}

class Podcast {
  final String feedUrl;
  final String title;
  final String author;
  final String? image;
  const Podcast(this.feedUrl, this.title, this.author, this.image);
}
