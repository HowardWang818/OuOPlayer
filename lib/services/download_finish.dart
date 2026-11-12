import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../data/db/database.dart';
import '../data/models/track.dart';
import 'cover_finder.dart';
import 'download_service.dart';
import 'missing_songs.dart';
import 'song_matcher.dart';
import 'tag_backlog.dart';
import 'tag_editor.dart';

/// After every download (1.20.0), before 原文歌名 and 歌詞: the names the
/// song was found by (a search result, or the missing song it fills), and a
/// square cover — the search result's when it is square, otherwise one
/// found by name when it is surely the same song. Written into the file too.
class DownloadFinish {
  /// Covers that are square already: YT Music's and SoundCloud's.
  static bool squareArt(String? url) =>
      url != null && (url.contains('googleusercontent.com') || url.contains('ggpht.com') || url.contains('sndcdn.com'));

  /// The names to give [t]: the task's, when it was started with them.
  static ({String title, String artist, String album}) names(Track t, DownloadTask task) => (
        title: task.metaTitle?.trim().isNotEmpty == true ? task.metaTitle!.trim() : t.title,
        artist: task.metaArtist?.trim().isNotEmpty == true ? task.metaArtist!.trim() : t.artist,
        album: task.metaAlbum?.trim().isNotEmpty == true ? task.metaAlbum!.trim() : t.album,
      );

  static Future<Track> apply(
    Track t,
    DownloadTask task, {
    required AppDatabase db,
    required Future<String> Function(Uint8List bytes, String mime) storeArt,
    required CoverFinder finder,
    Dio? dio,
  }) async {
    final n = names(t, task);
    var named = Track(
        id: t.id, uri: t.uri, title: n.title, artist: n.artist, album: n.album, durationMs: t.durationMs, art: t.art, source: t.source, trackNo: t.trackNo, addedAt: t.addedAt);
    Uint8List? cover;
    try {
      if (squareArt(task.art)) {
        final res = await (dio ?? Dio()).get<List<int>>(_bigger(task.art!), options: Options(responseType: ResponseType.bytes));
        cover = Uint8List.fromList(res.data!);
      } else if (CoverFinder.wantsCover(named)) {
        // A video's thumbnail: a square cover only when surely the same song.
        final hit = await finder.find(named);
        if (hit != null && hit.level == MatchLevel.sure) cover = await finder.download(hit.url);
      }
    } catch (_) {}
    final art = cover == null ? t.art : await storeArt(cover, 'image/jpeg');
    if (n.title == t.title && n.artist == t.artist && n.album == t.album && art == t.art) return t;
    named = Track(
        id: t.id, uri: t.uri, title: n.title, artist: n.artist, album: n.album, durationMs: t.durationMs, art: art, source: t.source, trackNo: t.trackNo, addedAt: t.addedAt);
    if (!await writeTagsQuietly(t.uri, TagEdit(title: n.title, artist: n.artist, album: n.album, cover: cover))) {
      await TagBacklog.add(db, [t.id]);
    }
    await db.updateTrackInfo(named);
    // The names may now match a missing song it was downloaded for.
    await MissingSongs.fill(db, [named]);
    return named;
  }

  /// The largest size of a YT Music / SoundCloud cover.
  static String _bigger(String url) =>
      url.replaceFirst(RegExp(r'=w\d+-h\d+'), '=w1200-h1200').replaceFirst(RegExp(r'-t\d+x\d+\.'), '-t500x500.');
}
