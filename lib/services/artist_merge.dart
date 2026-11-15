import 'dart:convert';

import '../data/db/database.dart';
import 'artists.dart';
import 'native_names.dart' show hasNativeText;
import 'song_matcher.dart' show foldText;

/// One artist under two names (1.20.12): 改成原文歌名 renames only the songs
/// it is sure of, so 「Rokudenashi」 and 「ロクデナシ」 ended up as two
/// artists. Once a song's artist goes from the romaji name to the original
/// one, the romaji name is shown as the original everywhere, through the
/// same table as 「重新命名歌手」 (names only: the files stay as they are).
class ArtistMerge {
  static const _renames = 'artist_renames';

  /// Romaji names merged this way (folded → the original name).
  static const _auto = 'artist_merge_auto';

  /// Romaji names never merged again: 「還原原本的名字」, or two originals.
  static const _skip = 'artist_merge_skip';

  static const _oldDone = 'artist_merge_v1';

  static Map<String, String> _map(String? raw) {
    try {
      return raw == null || raw.isEmpty ? {} : (jsonDecode(raw) as Map).cast<String, String>();
    } catch (_) {
      return {};
    }
  }

  static Set<String> _set(String? raw) {
    try {
      return raw == null || raw.isEmpty ? {} : {...(jsonDecode(raw) as List).cast<String>()};
    } catch (_) {
      return {};
    }
  }

  /// The romaji → original pairs of a credit renamed [from] → [to]
  /// (「Rokudenashi, X」→「ロクデナシ, X」 gives Rokudenashi → ロクデナシ).
  static List<(String, String)> pairs(String from, String to) {
    final a = splitArtists(from), b = splitArtists(to);
    if (a.length != b.length) return const [];
    return [
      for (var i = 0; i < a.length; i++)
        if (!hasNativeText(a[i]) && hasNativeText(b[i]) && foldText(a[i]).isNotEmpty) (a[i].trim(), b[i].trim()),
    ];
  }

  /// A song's artist went from [from] to [to].
  static Future<void> learn(AppDatabase db, String from, String to) => learnAll(db, pairs(from, to));

  static Future<void> learnAll(AppDatabase db, List<(String, String)> found) async {
    if (found.isEmpty) return;
    final s = await db.allSettings();
    final renames = _map(s[_renames]);
    final auto = _map(s[_auto]);
    final skip = _set(s[_skip]);
    var changed = false;
    for (final (latin, native) in found) {
      final key = foldText(latin);
      if (skip.contains(key)) continue;
      final known = auto[key];
      if (known != null) {
        if (foldText(known) == foldText(native)) continue;
        // Two different originals for one romaji name: can't tell, so neither.
        renames.removeWhere((k, v) => foldText(k) == key && foldText(v) == foldText(known));
        auto.remove(key);
        skip.add(key);
        changed = true;
        continue;
      }
      // The user's own name for it stays.
      if (renames.keys.any((k) => foldText(k) == key)) continue;
      renames[latin] = native;
      auto[key] = native;
      changed = true;
    }
    if (!changed) return;
    await db.setSetting(_renames, jsonEncode(renames));
    await db.setSetting(_auto, jsonEncode(auto));
    await db.setSetting(_skip, jsonEncode(skip.toList()));
    ArtistRenames.set(renames);
    db.notifyChanged();
  }

  /// 「還原原本的名字」 of these romaji names: never merged by itself again.
  static Future<void> keepApart(AppDatabase db, Iterable<String> originals) async {
    final s = await db.allSettings();
    final skip = _set(s[_skip])..addAll(originals.map(foldText));
    final auto = _map(s[_auto])..removeWhere((k, _) => skip.contains(k));
    await db.setSetting(_skip, jsonEncode(skip.toList()));
    await db.setSetting(_auto, jsonEncode(auto));
  }

  /// Once: the renames made before 1.20.12 (改成原文歌名's records, and the
  /// songs whose names other devices changed).
  static Future<void> learnOld(AppDatabase db) async {
    final s = await db.allSettings();
    if (s[_oldDone] == '1') return;
    final found = <(String, String)>[];
    for (final e in _names(s['sync_names']).values) {
      final from = e['from'];
      if (from is Map && e['artist'] is String) found.addAll(pairs('${from['artist']}', e['artist'] as String));
    }
    // Songs renamed through sync: their first name is only kept folded, so
    // the romaji name is taken as written on another song here, if any.
    final written = <String, String>{};
    for (final r in await db.db.rawQuery('SELECT DISTINCT artist FROM tracks')) {
      final a = '${r['artist']}';
      if (!hasNativeText(a)) written.putIfAbsent(foldText(a), () => a);
    }
    for (final r in await db.db.query('track_edits', columns: ['root', 'artist'])) {
      final root = '${r['root']}';
      final cut = root.lastIndexOf('|');
      final now = r['artist'] as String?;
      if (cut < 0 || now == null || splitArtists(now).length != 1 || !hasNativeText(now)) continue;
      final was = root.substring(cut + 1);
      if (was.isEmpty || hasNativeText(was)) continue;
      found.add((written[was] ?? was, now.trim()));
    }
    await learnAll(db, found);
    await db.setSetting(_oldDone, '1');
  }

  static Map<String, Map> _names(String? raw) {
    try {
      return raw == null || raw.isEmpty ? {} : (jsonDecode(raw) as Map).cast<String, Map>();
    } catch (_) {
      return {};
    }
  }
}
