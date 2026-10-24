import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/db/database.dart';
import 'package:ouoplayer/data/models/track.dart';

import 'v0120_test.dart' as v0120;

void main() {
  test('clearing play data removes only what was ticked', () async {
    final db = await v0120.openDb();
    const t = Track(id: 'a', uri: 'a', title: 'a', source: TrackSource.download);
    await db.db.insert('tracks', t.toMap());
    await db.addHistory(t);
    await db.startListening(t, DateTime(2026, 10, 24));
    await db.savePodcastProgress('https://x/ep.mp3', const Duration(minutes: 3), null);
    await db.db.insert('favorites', {'track_id': 'a', 'added_at': 1});
    final pl = await db.createPlaylist('通勤');
    await db.addToPlaylist(pl, [t]);

    await db.clearPlayData({PlayData.listening, PlayData.playCounts, PlayData.recent});
    expect(await db.db.query('listening_log'), isEmpty);
    expect(await db.playCounts(), isEmpty);
    expect(await db.recentlyPlayed(), isEmpty);
    // Not ticked, and never touched: podcast progress, likes, playlists, songs.
    expect((await db.podcastProgress()).keys, ['https://x/ep.mp3']);
    expect(await db.favoriteIds(), {'a'});
    expect((await db.playlistTracks(pl)).single.id, 'a');
    expect((await db.tracks()).single.id, 'a');

    await db.clearPlayData({PlayData.podcastProgress});
    expect(await db.podcastProgress(), isEmpty);
  });
}
