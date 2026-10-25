import 'dart:async';

import '../config/demo.dart';

import 'artist_images.dart';

import 'package:audio_service/audio_service.dart';
import 'package:rxdart/rxdart.dart';

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

  /// The four tabs, laid out like the phone app (Android Auto shows at most four).
  static const home = 'home';
  static const library = 'library';
  static const podcasts = 'podcasts';
  static const albums = 'albums';
  static const artists = 'artists';
  static const liked = 'liked';

  /// Big lists are cut short; the car's screen can't show more anyway.
  static const maxItems = 200;
  static const homeRow = 8;

  // Android Auto layout hints (androidx.media.utils.MediaConstants). Newer
  // versions read them from each folder, so every folder carries its own.
  static const browsableHint = 'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT';
  static const playableHint = 'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT';
  static const groupTitle = 'android.media.browse.CONTENT_STYLE_GROUP_TITLE_HINT';
  static const styleList = 1, styleGrid = 2;

  /// Given to AudioServiceConfig: defaults, plus the search button.
  static const rootExtras = <String, dynamic>{
    'android.media.browse.CONTENT_STYLE_SUPPORTED': true,
    browsableHint: styleGrid,
    playableHint: styleList,
    'android.media.browse.SEARCH_SUPPORTED': true,
  };

  static const _artAuthority = '$appPackage.art';

  /// The car can't open the app's files: local covers go through
  /// ArtProvider (which only serves the art cache and playlist covers),
  /// cropped to a square, or a circle for artists.
  static Uri? artUri(String? art, {bool circle = false}) {
    if (art == null || art.isEmpty) return null;
    if (art.startsWith('http')) return Uri.tryParse(art);
    return Uri.parse('content://$_artAuthority/${circle ? 'circle' : 'sq'}/${Uri.encodeComponent(art)}');
  }

  /// A folder icon on an accent tile (for grids).
  static Uri icon(String name) => Uri.parse('content://$_artAuthority/icon/$name');

  /// A tab icon: a plain vector the car tints itself.
  static Uri tabIcon(String drawable) => Uri.parse('android.resource://$appPackage/drawable/$drawable');

  /// A browsable entry. [children]: how its own content is laid out.
  static MediaItem folder(String id, String title,
          {String? subtitle, String? art, bool circle = false, String? icon, Uri? iconUri, String? group, int children = styleGrid}) =>
      MediaItem(
        id: id,
        title: title,
        artist: subtitle,
        playable: false,
        artUri: artUri(art, circle: circle) ?? iconUri ?? (icon == null ? null : CarBrowser.icon(icon)),
        extras: {
          if (group != null) groupTitle: group,
          browsableHint: children,
          playableHint: styleList,
        },
      );

  /// A list of songs (playlist, album…): opens as a list.
  static MediaItem songList(String id, String title, {String? subtitle, String? art, String? icon, String? group}) =>
      folder(id, title, subtitle: subtitle, art: art, icon: icon, group: group, children: styleList);

  Future<List<MediaItem>> children(String parent) async {
    switch (parent) {
      case root:
        return [
          folder(home, '首頁', iconUri: tabIcon('car_home')),
          songList(recent, '最近播放', icon: 'recent').copyWith(artUri: tabIcon('car_recent')),
          folder(library, '音樂庫', iconUri: tabIcon('car_library')),
          folder(podcasts, 'Podcast', iconUri: tabIcon('car_podcast')),
        ];
      case home:
        // Like the phone's home page.
        final recentAlbums = <String, Track>{};
        for (final t in await db.recentlyPlayed(limit: 40)) {
          if (t.album != '未知專輯') recentAlbums.putIfAbsent(t.album, () => t);
        }
        return [
          songList(liked, '已按讚的歌曲', icon: 'favorite', group: '快速播放'),
          songList('smart:${SmartList.mostPlayed.name}', SmartList.mostPlayed.label, icon: 'smart', group: '快速播放'),
          songList('smart:${SmartList.recentlyAdded.name}', SmartList.recentlyAdded.label, icon: 'smart', group: '快速播放'),
          for (final t in recentAlbums.values.take(homeRow))
            songList('album:${t.album}', t.album, subtitle: t.artist, art: t.art, icon: 'album', group: '最近播放'),
          for (final a in await db.recentAlbums(limit: homeRow))
            songList('album:${a.name}', a.name, subtitle: a.artist, art: a.art, icon: 'album', group: '最近加入的專輯'),
          for (final p in (await db.playlists()).take(homeRow))
            songList('pl:${p.id}', p.name, subtitle: '${p.count} 首', art: p.art, icon: 'playlist', group: '你的播放清單'),
        ];
      case library:
        // Like the phone's library page.
        return [
          songList(liked, '已按讚的歌曲', icon: 'favorite', group: '播放清單'),
          for (final p in await db.playlists()) songList('pl:${p.id}', p.name, subtitle: '${p.count} 首', art: p.art, icon: 'playlist', group: '播放清單'),
          for (final s in SmartList.values) songList('smart:${s.name}', s.label, icon: 'smart', group: '智慧播放清單'),
          folder(albums, '專輯', icon: 'album', group: '瀏覽'),
          folder(artists, '演出者', icon: 'artist', group: '瀏覽'),
        ];
      case albums:
        return [
          for (final a in (await db.albums()).take(maxItems)) songList('album:${a.name}', a.name, subtitle: a.artist, art: a.art, icon: 'album'),
        ];
      case artists:
        return [
          for (final a in (await db.artists()).take(maxItems))
            folder('artist:${a.name}', a.name,
                subtitle: '${a.count} 首', art: ArtistImages.cached(a.name) ?? a.art, circle: true, icon: 'artist', children: styleList),
        ];
      case podcasts:
        return [
          for (final p in await db.podcasts()) songList('podcast:${p.feedUrl}', p.title, subtitle: p.author, art: p.image, icon: 'podcast'),
        ];
    }
    final tracks = [for (final t in await tracksOf(parent)) if (t.source != TrackSource.missing) t];
    return [
      for (var i = 0; i < tracks.length && i < maxItems; i++)
        MediaItem(
          id: '$parent#$i',
          title: tracks[i].title,
          artist: tracks[i].artist,
          album: tracks[i].album,
          duration: tracks[i].duration,
          artUri: artUri(tracks[i].art),
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

/// What the car is served. Android Auto can start the app and ask for the
/// root before the library is ready; answering with nothing would leave the
/// car empty for good, so requests wait for [browser], and setting it (or a
/// library change, see [changed]) makes the car reload what it has open.
class CarLibrary {
  CarLibrary({this.waitLimit = const Duration(seconds: 15)});
  final Duration waitLimit;

  CarBrowser? _browser;
  final _ready = Completer<void>();

  /// One stream per list the car has opened; an event reloads that list.
  final _lists = <String, BehaviorSubject<Map<String, dynamic>>>{};

  CarBrowser? get browser => _browser;
  set browser(CarBrowser? b) {
    _browser = b;
    if (b != null && !_ready.isCompleted) _ready.complete();
    changed();
  }

  void changed() {
    for (final s in _lists.values) {
      s.add(const {});
    }
  }

  ValueStream<Map<String, dynamic>> subscribe(String parentMediaId) =>
      _lists.putIfAbsent(parentMediaId, BehaviorSubject<Map<String, dynamic>>.new);

  Future<List<MediaItem>> children(String parentMediaId) async {
    try {
      if (_browser == null) await _ready.future.timeout(waitLimit);
      return await _browser?.children(parentMediaId) ?? const [];
    } catch (_) {
      return const [];
    }
  }
}
