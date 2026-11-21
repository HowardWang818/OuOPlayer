import 'dart:io';

import '../data/models/track.dart';
import 'playlist_import.dart' show LibraryMatcher;

/// 「Open OuOPlayer」 under the Discord status (1.21.0): the button opens the
/// listen page, which opens `ouoplayer://play?t=…&a=…&ms=…`; the song plays
/// when it is here, otherwise it is searched for online. Without OuOPlayer
/// the page goes on to GitHub.
class ListenLink {
  const ListenLink({required this.title, required this.artist, this.durationMs});
  final String title;
  final String artist;
  final int? durationMs;

  /// The listen page (GitHub Pages, branch gh-pages).
  static const page = 'https://howardwang818.github.io/OuOPlayer/listen/';

  /// The page for [t], for the Discord button.
  static String webUrl(Track t) => Uri.parse(page).replace(queryParameters: {
        't': t.title,
        if (t.artist.isNotEmpty && t.artist != '未知演出者') 'a': t.artist,
        if (t.durationMs != null) 'ms': '${t.durationMs}',
      }).toString();

  /// `ouoplayer://play?…` (or the page's own address) → the song; null for
  /// anything else.
  static ListenLink? parse(String? text) {
    if (text == null) return null;
    final uri = Uri.tryParse(text.trim());
    if (uri == null) return null;
    final ours = (uri.scheme == 'ouoplayer' && uri.host == 'play') || text.trim().startsWith(page);
    if (!ours) return null;
    final title = (uri.queryParameters['t'] ?? '').trim();
    if (title.isEmpty) return null;
    return ListenLink(
      title: title,
      artist: (uri.queryParameters['a'] ?? '').trim(),
      durationMs: int.tryParse(uri.queryParameters['ms'] ?? ''),
    );
  }

  /// The first `ouoplayer://` link among the program's arguments (Windows).
  static ListenLink? fromArgs(List<String> args) {
    for (final a in args) {
      final l = parse(a);
      if (l != null) return l;
    }
    return null;
  }

  /// The song here, with its file, or null.
  Track? findIn(List<Track> library) {
    final here = [for (final t in library) if (t.source != TrackSource.missing && !t.isRemote && t.uri.isNotEmpty && File(t.uri).existsSync()) t];
    return LibraryMatcher(here).find('', title: title, artist: artist, durationMs: durationMs);
  }

  /// What to search for online when the song isn't here.
  String get query => artist.isEmpty ? title : '$title $artist';
}

/// Links that came in (program arguments, a second start, Android): kept
/// until the app is ready to take them.
class LinkInbox {
  static final _waiting = <String>[];
  static void Function(String link)? _take;

  static void add(String link) {
    final take = _take;
    take == null ? _waiting.add(link) : take(link);
  }

  static void listen(void Function(String link) take) {
    _take = take;
    final waiting = [..._waiting];
    _waiting.clear();
    waiting.forEach(take);
  }
}
