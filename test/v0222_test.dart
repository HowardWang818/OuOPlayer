import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_media_kit/mediakit_player.dart';

/// [songs] after inserting [added] at [index], the way the player does it:
/// each one appended, then moved from the last place (mpv's `playlist-move`).
List<String> insert(List<String> songs, int index, List<String> added) {
  final list = [...songs];
  for (final (offset, song) in added.indexed) {
    list.add(song);
    final to = MediaKitPlayer.insertTarget(index, offset, list.length);
    if (to != null) list.insert(to, list.removeLast());
  }
  return list;
}

void main() {
  test('a queued song goes where it was inserted, not to the end', () {
    expect(insert(['a', 'b', 'c'], 1, ['x']), ['a', 'x', 'b', 'c']);
  });

  test('several keep their order', () {
    expect(insert(['a', 'b', 'c'], 1, ['x', 'y', 'z']), ['a', 'x', 'y', 'z', 'b', 'c']);
  });

  test('added at the end they stay there', () {
    expect(MediaKitPlayer.insertTarget(3, 0, 4), isNull);
    expect(insert(['a', 'b', 'c'], 3, ['x', 'y']), ['a', 'b', 'c', 'x', 'y']);
  });

  test('a move always starts from a real place and has a valid target', () {
    expect(MediaKitPlayer.insertTarget(0, 0, 1), isNull);
    expect(MediaKitPlayer.insertTarget(-1, 0, 3), isNull);
    expect(MediaKitPlayer.insertTarget(1, 1, 5), 2);
  });
}
