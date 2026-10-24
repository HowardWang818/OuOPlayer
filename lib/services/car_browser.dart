import 'package:audio_service/audio_service.dart';

import '../data/db/database.dart';
import '../data/models/track.dart';

/// The library as Android Auto (and other media browsers) see it: folders
/// of lists, lists of songs. A song's id is 「list id#index」, so playing it
/// queues the whole list from that song.
class CarBrowser {
  CarBrowser(this.db, {this.episodes});

  final AppDatabase db;

  /// Episodes of a subscribed podcast (fetched from its feed).
  final Future<List<Track>> Function(String feedUrl)? episodes;

  static const root = AudioService.browsableRootId;
  static const recent = AudioService.recentRootId;
  static const playlists = 'playlists';
  static const albums = 'albums';
  static const artists = 'artists';
  static const podcasts = 'podcasts';
  static const liked = 'liked';

  /// Big lists are cut short; the car's screen can't show more anyway.
  static const maxItems = 200;

  static MediaItem folder(String id, String title, {String? subtitle, String? art}) =>
      MediaItem(id: id, title: title, artist: subtitle, playable: false, artUri: _art(art));

  static Uri? _art(String? art) {
    if (art == null) return null;
    return art.startsWith('http') ? Uri.tryParse(art) : Uri.file(art);
  }

  Future<List<MediaItem>> children(String parent) async {
    switch (parent) {
      case root:
        return [
          folder(playlists, '播放清單'),
          folder(liked, '已按讚的歌曲'),
          folder(albums, '專輯'),
          folder(artists, '演出者'),
          folder(podcasts, 'Podcast'),
          folder(recent, '最近播放'),
        ];
      case playlists:
        return [
          for (final s in SmartList.values) folder('smart:${s.name}', s.label, subtitle: '智慧播放清單'),
          for (final p in await db.playlists()) folder('pl:${p.id}', p.name, subtitle: '${p.count} 首', art: p.art),
        ];
      case albums:
        return [for (final a in (await db.albums()).take(maxItems)) folder('album:${a.name}', a.name, subtitle: a.artist, art: a.art)];
      case artists:
        return [for (final a in (await db.artists()).take(maxItems)) folder('artist:${a.name}', a.name, subtitle: '${a.count} 首', art: a.art)];
      case podcasts:
        return [for (final p in await db.podcasts()) folder('podcast:${p.feedUrl}', p.title, subtitle: p.author, art: p.image)];
    }
    final tracks = await tracksOf(parent);
    return [
      for (var i = 0; i < tracks.length && i < maxItems; i++)
        MediaItem(
          id: '$parent#$i',
          title: tracks[i].title,
          artist: tracks[i].artist,
          album: tracks[i].album,
          duration: tracks[i].duration,
          artUri: _art(tracks[i].art),
          playable: true,
        ),
    ];
  }

  /// The songs of a list id (empty for unknown ids).
  Future<List<Track>> tracksOf(String listId) async {
    final colon = listId.indexOf(':');
    final kind = colon < 0 ? listId : listId.substring(0, colon);
    final arg = colon < 0 ? '' : listId.substring(colon + 1);
    switch (kind) {
      case liked:
        return db.favorites();
      case recent:
        return db.recentlyPlayed(limit: 50);
      case 'pl':
        final id = int.tryParse(arg);
        return id == null ? const [] : db.playlistTracks(id);
      case 'smart':
        final s = SmartList.values.where((s) => s.name == arg).firstOrNull;
        return s == null ? const [] : db.smartTracks(s);
      case 'album':
        return db.albumTracks(arg);
      case 'artist':
        return db.artistTracks(arg);
      case 'podcast':
        return episodes == null ? const [] : episodes!(arg);
      case 'search':
        return db.search(arg);
    }
    return const [];
  }

  /// 「list#index」 → the list and where to start.
  Future<(List<Track>, int)?> resolve(String mediaId) async {
    final hash = mediaId.lastIndexOf('#');
    if (hash < 0) return null;
    final index = int.tryParse(mediaId.substring(hash + 1));
    if (index == null) return null;
    final list = await tracksOf(mediaId.substring(0, hash));
    if (index < 0 || index >= list.length) return null;
    return (list, index);
  }

  /// Voice / text search from the car.
  Future<List<MediaItem>> search(String query) => children('search:${query.trim()}');
}
