import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';

import '../data/db/database.dart';
import '../data/models/track.dart';
import 'tag_editor.dart';

/// Songs whose names were changed in OuOPlayer (by hand or by another
/// device) while their files still carry the old ones: .opus files before
/// v1.15.0, or on Android files the app may not write without asking. They
/// are written in one go: Android asks once for all of them.
class TagBacklog {
  static const _key = 'tags_pending';
  static const _checked = 'tags_checked';

  static Future<Set<String>> _ids(AppDatabase db) async {
    try {
      return {...(jsonDecode((await db.allSettings())[_key] ?? '[]') as List).cast<String>()};
    } catch (_) {
      return {};
    }
  }

  static Future<void> _save(AppDatabase db, Set<String> ids) => db.setSetting(_key, jsonEncode(ids.toList()));

  static Future<void> add(AppDatabase db, Iterable<String> ids) async => _save(db, {...await _ids(db), ...ids});

  static bool _writable(Track t) =>
      (t.source == TrackSource.local || t.source == TrackSource.download) && canWriteTags(t.uri) && t.fileExists;

  /// Once (v1.15.0): renamed songs whose files still say something else.
  static Future<void> findOld(AppDatabase db) async {
    if ((await db.allSettings())[_checked] == '1') return;
    final edited = {for (final r in await db.db.query('track_edits', columns: ['track_id'])) '${r['track_id']}'};
    final songs = [for (final t in await db.tracks()) if (edited.contains(t.id) && _writable(t)) t];
    final names = {for (final t in songs) t.uri: (t.title, t.artist)};
    final stale = await Isolate.run(() => [
          for (final e in names.entries)
            if (!_same(e.key, e.value)) e.key,
        ]);
    await add(db, [for (final t in songs) if (stale.contains(t.uri)) t.id]);
    await db.setSetting(_checked, '1');
  }

  static bool _same(String path, (String, String) name) {
    try {
      final m = readMetadata(File(path));
      return m.title == name.$1 && (m.artist ?? '') == name.$2;
    } catch (_) {
      return true; // unreadable: leave it alone
    }
  }

  /// The songs still waiting.
  static Future<List<Track>> songs(AppDatabase db) async {
    final ids = await _ids(db);
    if (ids.isEmpty) return const [];
    return [for (final t in await db.tracks()) if (ids.contains(t.id) && _writable(t)) t];
  }

  /// Writes what it can without asking (all of them on Windows); the rest wait.
  static Future<void> writeQuietly(AppDatabase db) async {
    final done = <String>{};
    for (final t in await songs(db)) {
      try {
        if (await writeTagsQuietly(t.uri, _edit(t))) done.add(t.id);
      } catch (_) {}
    }
    if (done.isNotEmpty) await _save(db, (await _ids(db)).difference(done));
  }

  /// Writes [songs] (Android asks once); returns how many were written.
  static Future<int> write(AppDatabase db, List<Track> songs) async {
    final written = (await writeTagsMany({for (final t in songs) t.uri: _edit(t)})).toSet();
    // Not allowed: they wait for the next time. Allowed: the ones whose file
    // couldn't take the names leave too (asked again when they change again).
    if (written.isNotEmpty) await _save(db, (await _ids(db)).difference({for (final t in songs) t.id}));
    return written.length;
  }

  static TagEdit _edit(Track t) => TagEdit(title: t.title, artist: t.artist, album: t.album);
}
