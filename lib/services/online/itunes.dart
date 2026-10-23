import 'dart:convert';
import 'dart:ui';

import 'package:dio/dio.dart';

import '../../data/models/track.dart';

/// One song from the iTunes Search API (free, no account or key).
class ITunesSong {
  final int id;
  final String title;
  final String artist;
  final String album;
  final String? artwork;
  final String? previewUrl;
  final int? durationMs;
  final String viewUrl;

  const ITunesSong({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.viewUrl,
    this.artwork,
    this.previewUrl,
    this.durationMs,
  });

  factory ITunesSong.fromJson(Map<String, dynamic> j) => ITunesSong(
        id: j['trackId'] as int,
        title: j['trackName'] as String? ?? '',
        artist: j['artistName'] as String? ?? '',
        album: j['collectionName'] as String? ?? '',
        // The API returns 100x100 art; the same path serves larger sizes.
        artwork: (j['artworkUrl100'] as String?)?.replaceFirst('100x100bb', '600x600bb'),
        previewUrl: j['previewUrl'] as String?,
        durationMs: j['trackTimeMillis'] as int?,
        viewUrl: j['trackViewUrl'] as String? ?? '',
      );

  /// The 30-second preview as a playable track.
  Track? get previewTrack => previewUrl == null
      ? null
      : Track.fromUrl(previewUrl!, title: '$title（試聽）', artist: artist, album: album, art: artwork, durationMs: 30000);

  String get query => '$title $artist';

  /// Apple Music page.
  String get appleMusicUrl => viewUrl;

  /// Same page opened in the iTunes Store (purchase).
  String get iTunesStoreUrl => viewUrl.contains('?') ? '$viewUrl&app=itunes' : '$viewUrl?app=itunes';

  /// song.link lists the song on every platform (Spotify, YouTube Music, KKBOX…).
  String get songLinkUrl => 'https://song.link/i/$id';

  String get moraUrl => 'https://mora.jp/search/top?keyWord=${Uri.encodeQueryComponent(query)}';

  String get ototoyUrl => 'https://ototoy.jp/find/?q=${Uri.encodeQueryComponent(query)}';
}

class ITunesSearch {
  ITunesSearch({Dio? dio}) : _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 10), receiveTimeout: const Duration(seconds: 15)));

  final Dio _dio;

  /// Storefront follows the device region (falls back to Taiwan).
  static String get country {
    final c = PlatformDispatcher.instance.locale.countryCode;
    return (c == null || c.length != 2) ? 'TW' : c;
  }

  Future<List<ITunesSong>> search(String query, {int limit = 25}) async {
    final res = await _dio.get<String>(
      'https://itunes.apple.com/search',
      queryParameters: {'term': query, 'entity': 'song', 'limit': limit, 'country': country},
      // Served as text/javascript, so parse it ourselves.
      options: Options(responseType: ResponseType.plain),
    );
    return parse(res.data ?? '');
  }

  static List<ITunesSong> parse(String body) {
    final results = (jsonDecode(body) as Map<String, dynamic>)['results'] as List? ?? const [];
    return results
        .cast<Map<String, dynamic>>()
        .where((r) => r['wrapperType'] == 'track' && r['trackId'] != null)
        .map(ITunesSong.fromJson)
        .toList();
  }
}
