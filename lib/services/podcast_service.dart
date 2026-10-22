import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

import '../data/models/track.dart';

class PodcastFeed {
  final Podcast podcast;
  final List<Track> episodes;
  final Map<String, String> descriptions;
  const PodcastFeed(this.podcast, this.episodes, this.descriptions);
}

class PodcastService {
  final _dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 15), receiveTimeout: const Duration(seconds: 30)));

  Future<PodcastFeed> fetch(String feedUrl) async {
    final res = await _dio.get<String>(feedUrl, options: Options(responseType: ResponseType.plain));
    final doc = XmlDocument.parse(res.data ?? '');
    final channel = doc.findAllElements('channel').first;
    String? text(XmlElement e, String name) {
      final found = e.childElements.where((c) => c.name.qualified == name || c.name.local == name);
      return found.isEmpty ? null : found.first.innerText.trim();
    }

    final image = channel.findElements('itunes:image').firstOrNull?.getAttribute('href') ??
        channel.findElements('image').firstOrNull?.findElements('url').firstOrNull?.innerText.trim();
    final podcast = Podcast(
      feedUrl,
      text(channel, 'title') ?? feedUrl,
      text(channel, 'itunes:author') ?? text(channel, 'author') ?? '',
      image,
    );
    final episodes = <Track>[];
    final descriptions = <String, String>{};
    for (final item in channel.findElements('item')) {
      final enclosure = item.findElements('enclosure').firstOrNull;
      final url = enclosure?.getAttribute('url');
      if (url == null) continue;
      final epImage = item.findElements('itunes:image').firstOrNull?.getAttribute('href') ?? image;
      episodes.add(Track.fromUrl(
        url,
        title: text(item, 'title') ?? url,
        artist: podcast.title,
        album: podcast.title,
        art: epImage,
        source: TrackSource.podcast,
        durationMs: parseDuration(text(item, 'itunes:duration')),
      ));
      final pub = text(item, 'pubDate');
      if (pub != null) descriptions[url] = pub.length > 16 ? pub.substring(0, 16) : pub;
    }
    return PodcastFeed(podcast, episodes, descriptions);
  }

  static int? parseDuration(String? s) {
    if (s == null || s.isEmpty) return null;
    final parts = s.split(':').map((e) => int.tryParse(e) ?? 0).toList();
    var secs = 0;
    for (final x in parts) {
      secs = secs * 60 + x;
    }
    return secs * 1000;
  }
}
