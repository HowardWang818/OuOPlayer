import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/services/backup.dart';
import 'package:ouoplayer/ui/widgets/backup_actions.dart';

void main() {
  test('every part of a backup has its line in the restore list', () {
    for (final data in <Map<String, Object?>>[
      {},
      {'library': []},
    ]) {
      for (final part in RestorePart.values) {
        expect(restorePartSummary(part, data), isNotEmpty, reason: part.name);
      }
    }
  });

  test('the list says what an older backup can give back', () {
    expect(restorePartSummary(RestorePart.songs, {}), contains('舊版'));
    expect(restorePartSummary(RestorePart.songs, {'library': List.filled(3, {})}), contains('3 首'));
  });

  test('a backup file from an older version reads the same', () {
    final f = File('${Directory.systemTemp.createTempSync('ouo').path}/b.json')
      ..writeAsStringSync(jsonEncode({
        'app': 'OuOPlayer',
        'settings': {'a': 'b'},
        'playlists': [{}],
      }));
    final data = (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>();
    expect(restorePartSummary(RestorePart.settings, data), '1 項');
    expect(restorePartSummary(RestorePart.playlists, data), contains('1 個播放清單'));
  });
}
