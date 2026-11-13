import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart' show CancelToken, DioException;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../../data/db/database.dart';
import '../../data/models/track.dart';
import '../../theme/looks.dart';
import '../missing_songs.dart';
import '../playlist_import.dart';
import '../sync/drive_client.dart';
import 'edits.dart';
import 'merge.dart';
import 'sync_log.dart';
import 'now_playing.dart';
import 'plays.dart';

/// What one sync did.
class SyncResult {
  SyncResult({this.changed = 0, this.deleted = const [], this.uploads = 0, this.downloads = 0, this.incomplete = false, this.sent = 0, this.received = 0});
  final int changed;

  /// Changes this device sent / got (playlist entries, song details, plays).
  final int sent;
  final int received;

  /// A synced song is still missing on a device: sync again soon.
  final bool incomplete;

  /// Playlists the other device deleted and the user agreed to delete here.
  final List<String> deleted;

  /// Songs waiting to go up / come down (see [SyncEngine.runTransfers]).
  final int uploads;
  final int downloads;
}

/// Progress of the songs on their way, for the notification / taskbar.
class TransferProgress {
  const TransferProgress({required this.done, required this.total, required this.title, required this.upload, required this.fraction, this.paused = false, this.full = false});
  final int done;
  final int total;
  final String title;
  final bool upload;
  final double fraction;
  final bool paused;

  /// The relay on Drive is full: uploads wait for the other device to download.
  final bool full;
}

/// Playlist sync through the user's Google Drive (app folder), no server:
/// - each device writes only its own `v2-state-<device>.json`: its synced
///   playlists as [ListState]s (what the user did to them) and which of their
///   songs it has (`have`);
/// - a song a device lacks goes up once as `v2-song-<sha256>` (listed in the
///   uploader's `v2-relay-<device>.json`) and is removed once every other
///   device has it, so Drive is only a relay;
/// - files disappearing from a device, folders removed, songs hidden are never
///   playlist actions: synced playlists keep such songs, greyed;
/// - every sync compares again: a song one device lacks is sent as long as
///   another has it (pausing only stops the current round), unless the
///   lacking device removed it from its library itself.
class SyncEngine implements SyncHooks {
  SyncEngine({
    required this.db,
    required this.drive,
    required this.deviceId,
    required this.deviceName,
    required this.importFile,
    required this.storeArt,
    required this.downloadDir,
    LyricsOf? lyricsOf,
    Future<void> Function(Track t, String lrc, bool manual)? setLyrics,
    Future<void> Function(Track t, Uint8List? cover)? writeTags,
    int Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    db.syncHooks = this;
    edits = EditSync(db: db, drive: drive, lyricsOf: lyricsOf, setLyrics: setLyrics, writeTags: writeTags, storeArt: storeArt);
    edits.onApplied = (before, after, cover, device) => _logged.add(SyncLogEntry(
        DateTime.now(),
        [if (before != after) '歌名「$before」改為「$after」', if (cover) '「$after」更換封面'].join('，'),
        device: _deviceNames[device]));
    plays = PlaySync(db);
    nowPlaying = NowPlayingStore(drive);
  }

  late final EditSync edits;
  late final PlaySync plays;

  /// 接續播放's files (used by the sync provider).
  late final NowPlayingStore nowPlaying;

  final AppDatabase db;
  final DriveStore drive;
  final Future<String> Function() deviceId;
  final String deviceName;
  final Future<Track?> Function(String path) importFile;
  final Future<String> Function(Uint8List bytes, String mime) storeArt;
  final String Function() downloadDir;
  final int Function() _clock;

  static const likedId = 'liked';
  static const _active = Duration(days: 30);
  final _random = Random.secure();

  /// Set while sync itself writes the library (those aren't user actions).
  /// Sync's own writes run in a zone marked with this, inside the library's
  /// turn (AppDatabase.exclusive): the hooks skip them, and only them.
  static const _syncZone = #ouoSyncApplying;
  bool get _own => Zone.current[_syncZone] == true;
  Future<T> _asSync<T>(Future<T> Function() fn) => db.exclusive(() => runZoned(fn, zoneValues: {_syncZone: true}));

  String _newId() => List.generate(14, (_) => _random.nextInt(36).toRadixString(36)).join();

  static Map<String, Object?> ref(Track t) => {'t': t.title, 'a': t.artist, 'al': t.album, 'ms': t.durationMs};

  // ---------- local state ----------

  Future<Map<String, ListState>> states() async => {
        for (final r in await db.db.query('sync_lists')) r['sid'] as String: ListState.fromJson(jsonDecode(r['state'] as String) as Map),
      };

  Future<void> _save(String sid, ListState s) =>
      db.db.insert('sync_lists', {'sid': sid, 'state': jsonEncode(s.toJson())}, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> _drop(String sid) => db.db.delete('sync_lists', where: 'sid = ?', whereArgs: [sid]);

  Future<Map<String, String>> _settings() => db.allSettings();

  Future<Set<String>> _set(String key) async {
    try {
      return {...(jsonDecode((await _settings())[key] ?? '[]') as List).cast<String>()};
    } catch (_) {
      return {};
    }
  }

  Future<void> _putSet(String key, Set<String> v) => db.setSetting(key, jsonEncode(v.toList()));

  /// Marks of songs 'not wanted' (1.20.6: gone). A song in a synced
  /// playlist always comes to the device that lacks it; to not have it,
  /// it's taken out of the playlist. Cleared on the first sync.
  static const _oldMarks = ['sync2_cancelled', 'sync2_removed', 'sync_skip', 'sync_declined'];

  /// This device's relay index on Drive is read and written one at a time
  /// (an upload and a sync's clean-up writing it together lost entries).
  Future<void> _indexLock = Future.value();
  Future<T> _locked<T>(Future<T> Function() f) {
    final run = _indexLock.then((_) => f());
    _indexLock = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<bool> get likedSynced async => (await _settings())['sync_liked'] == 'true';

  Future<bool> isSynced(int playlistId) async =>
      (await db.db.query('playlists', columns: ['synced'], where: 'id = ?', whereArgs: [playlistId])).firstOrNull?['synced'] == 1;

  /// Playlists that are synced (id → name).
  Future<Set<int>> syncedPlaylists() async => {for (final r in await db.db.query('playlists', columns: ['id'], where: 'synced = 1')) r['id'] as int};

  // ---------- turning sync on / off ----------

  /// 同步這個清單: its songs now as the starting point.
  Future<void> enable(int playlistId) async {
    final row = (await db.db.query('playlists', where: 'id = ?', whereArgs: [playlistId])).firstOrNull;
    if (row == null) return;
    final sid = (row['uid'] as String?) ?? _newId();
    await db.db.update('playlists', {'uid': sid, 'synced': 1}, where: 'id = ?', whereArgs: [playlistId]);
    final me = await deviceId();
    await _save(sid, ListState(name: Stamped('${row['name']}', _clock(), me)));
    await playlistEdited(playlistId);
    // Matched by name with the other device's list on the first sync.
    await _putSet('sync2_fresh', {...await _set('sync2_fresh'), sid});
  }

  /// 停止同步: the playlist stays here as it is, and on the other device too.
  Future<void> disable(int playlistId) async {
    final row = (await db.db.query('playlists', where: 'id = ?', whereArgs: [playlistId])).firstOrNull;
    if (row == null) return;
    await db.db.update('playlists', {'synced': 0, 'uid': _newId()}, where: 'id = ?', whereArgs: [playlistId]);
    final sid = row['uid'] as String?;
    if (sid != null) {
      await _drop(sid);
      // The other device still syncs it: don't bring it back here.
      await _putSet('sync2_ignored', {...await _set('sync2_ignored'), sid});
    }
    db.notifyChanged();
  }

  Future<void> setLikedSynced(bool on) async {
    await db.setSetting('sync_liked', '$on');
    if (on) {
      await likesEdited();
    } else {
      await _drop(likedId);
    }
  }

  // ---------- the user's actions (SyncHooks) ----------

  @override
  Future<void> playlistEdited(int playlistId) async {
    if (_own) return;
    final row = (await db.db.query('playlists', where: 'id = ?', whereArgs: [playlistId])).firstOrNull;
    if (row == null || row['synced'] != 1 || row['uid'] == null) return;
    final sid = row['uid'] as String;
    final me = await deviceId();
    final now = _clock();
    var state = (await states())[sid] ?? ListState();
    final rows = await db.playlistRows(playlistId);
    final tracks = {for (final t in await db.playlistTracks(playlistId)) t.id: t};
    final local = [for (final (tid, item) in rows) LocalRow(item, tracks[tid] == null ? const {} : ref(tracks[tid]!))];
    final rec = recordRows(state, local, now, me, _newId);
    state = rec.state;
    if (state.name?.value != row['name']) state = ListState(name: Stamped('${row['name']}', now, me), deleted: state.deleted, items: state.items);
    await _save(sid, state);
    // New entries get their ids in the library too.
    if ([for (final r in rows) r.$2].join('|') != rec.ids.join('|')) {
      await _asSync(() async {
        await db.setPlaylistRows(playlistId, [for (var i = 0; i < rows.length; i++) (rows[i].$1, rec.ids[i])]);
      });
    }
  }

  /// 刪除 a synced playlist (1.20.6): only here. The other devices keep it,
  /// and the next sync brings it back here whole.
  @override
  Future<void> playlistDeleted(String? uid) async {
    if (_own || uid == null) return;
    await _drop(uid);
  }

  @override
  Future<void> likesEdited() async {
    if (_own || !await likedSynced) return;
    final me = await deviceId();
    final now = _clock();
    final state = (await states())[likedId] ?? ListState();
    final liked = {for (final t in await db.favorites()) songKey(t.title, t.artist): t};
    final items = Map.of(state.items);
    final shown = {for (final e in state.shown) e.value.key: e.key};
    for (final MapEntry(key: k, value: t) in liked.entries) {
      if (shown.containsKey(k)) continue;
      final id = items.containsKey('L|$k') ? 'L|$k|$now' : 'L|$k';
      items[id] = ListItem(song: ref(t), order: Stamped(now.toDouble(), now, me), addedAt: now);
    }
    for (final MapEntry(key: k, value: id) in shown.entries) {
      if (!liked.containsKey(k)) items[id] = items[id]!.copyWith(removedAt: now);
    }
    await _save(likedId, ListState(name: state.name, deleted: state.deleted, items: items));
  }

  /// Songs left the library here (hidden, folder removed, file gone): the
  /// synced playlists keep them, greyed — never an action for the other
  /// device — and another device sends them again.
  @override
  Future<void> songsRemoved(List<(String, String)> songs) async {
    if (_own) return;
    await applyAll();
  }

  /// A song's details changed by the user: shared with the other devices
  /// (when 歌曲資料 sync is on).
  @override
  Future<void> trackEdited(Track before, Track after) async {
    if (_own || (await _settings())['sync_edits'] == 'false') return;
    await edits.recorded(before, after, await deviceId(), _clock());
  }

  // ---------- making the library match the states ----------

  Future<void> applyAll() async {
    final all = await states();
    final r = await _Resolver.make(db);
    await _asSync(() async {
      for (final e in all.entries) {
        if (!e.value.isDeleted) await _apply(e.key, e.value, r);
      }
    });
  }

  Future<bool> _apply(String sid, ListState state, _Resolver r) async {
    if (sid == likedId) return _applyLiked(state, r);
    final row = (await db.db.query('playlists', where: 'uid = ?', whereArgs: [sid])).firstOrNull;
    int id;
    var changed = false;
    if (row == null) {
      id = await db.db.insert('playlists', {'name': state.name?.value ?? '播放清單', 'created_at': _clock(), 'uid': sid, 'synced': 1});
      changed = true;
    } else {
      if (row['synced'] != 1) return false;
      id = row['id'] as int;
      final name = state.name?.value;
      if (name != null && name != row['name']) {
        await db.db.update('playlists', {'name': name}, where: 'id = ?', whereArgs: [id]);
        changed = true;
      }
    }
    final rows = await db.playlistRows(id);
    final current = {for (final (tid, item) in rows) if (item != null) item: tid};
    final want = <(String, String?)>[];
    for (final e in state.shown) {
      want.add((current[e.key] ?? (await r.resolve(e.value.song)).id, e.key));
    }
    if ([for (final x in rows) '${x.$1}/${x.$2}'].join('|') != [for (final x in want) '${x.$1}/${x.$2}'].join('|')) {
      await db.setPlaylistRows(id, want);
      changed = true;
      // 同步紀錄: the songs this brought in or took out of the list.
      final before = {for (final x in rows) x.$2}, after = {for (final x in want) x.$2};
      final listName = state.name?.value ?? '播放清單';
      String title(String? tid) => _titles[tid] ?? '';
      final added = [for (final x in want) if (!before.contains(x.$2)) x.$1];
      final gone = [for (final x in rows) if (!after.contains(x.$2)) x.$1];
      _titles.addAll({for (final t in await db.tracksByIds([...added, ...gone])) t.id: t.title});
      _logged.addAll([
        for (final tid in added) SyncLogEntry(DateTime.now(), '「$listName」加入「${title(tid)}」', device: _from(sid)),
        for (final tid in gone) SyncLogEntry(DateTime.now(), '「$listName」移除「${title(tid)}」', device: _from(sid)),
      ]);
    }
    return changed;
  }

  /// Titles for the log, and what this sync brought in (written at its end).
  final _titles = <String?, String>{};
  final _logged = <SyncLogEntry>[];

  /// Device id → its name, from the other devices' state files.
  final _deviceNames = <String, String>{};

  Future<bool> _applyLiked(ListState state, _Resolver r) async {
    final liked = {for (final t in await db.favorites()) songKey(t.title, t.artist): t};
    final shown = {for (final e in state.shown) e.value.key: e.value};
    var changed = false;
    for (final MapEntry(key: k, value: item) in shown.entries) {
      if (liked.containsKey(k)) continue;
      final t = await r.resolve(item.song);
      await db.db.insert('favorites', {'track_id': t.id, 'added_at': item.addedAt}, conflictAlgorithm: ConflictAlgorithm.ignore);
      _logged.add(SyncLogEntry(DateTime.now(), '按讚「${t.title}」', device: _deviceNames[item.order.device] ?? _from(likedId)));
      changed = true;
    }
    final removed = {for (final i in state.items.values) if (!i.visible) i.key}..removeAll(shown.keys);
    for (final k in removed) {
      final t = liked[k];
      if (t == null) continue;
      await db.db.delete('favorites', where: 'track_id = ?', whereArgs: [t.id]);
      _logged.add(SyncLogEntry(DateTime.now(), '取消按讚「${t.title}」', device: _from(likedId)));
      changed = true;
    }
    if (changed) db.notifyChanged();
    return changed;
  }

  // ---------- one sync ----------

  /// Reads the other devices' states, merges, applies, writes this device's.
  Future<SyncResult> sync({int relayCap = 5 << 30}) async {
    final me = await deviceId();
    final mine = 'v2-state-$me.json';
    final files = await drive.list();
    final seen = _signature(me, files);
    final byName = {for (final f in files) f.name: f};
    var all = await states();
    final sentMarks = await _marks('sync2_sent_lists');
    var since = int.tryParse((await _settings())['sync2_since'] ?? '');
    if (since == null) {
      since = _clock();
      await db.setSetting('sync2_since', '$since');
    }
    _since = since;
    var sent = sentMarks == null ? 0 : _listMarks(all).entries.where((e) => sentMarks[e.key] != e.value).length;
    var received = 0;
    final remote = <String, _Remote>{};
    for (final f in files.where((f) => f.name.startsWith('v2-state-') && f.name != mine)) {
      try {
        final j = jsonDecode(utf8.decode(await drive.download(f.id))) as Map;
        if (j['name'] != null) _deviceNames['${j['device']}'] = '${j['name']}';
        remote['${j['device']}'] = _Remote(
          j['name'] as String?,
          (j['updated'] as num?)?.toInt() ?? 0,
          {...((j['have'] as List?) ?? const []).cast<String>()},
          {for (final e in ((j['lists'] as Map?) ?? const {}).entries) '${e.key}': ListState.fromJson(e.value as Map)},
          since: (j['since'] as num?)?.toInt() ?? 0,
        );
      } catch (_) {}
    }

    // A device syncing for the first time (a new install): its lists of the
    // same name are the same lists, not new ones beside them.
    if (sentMarks == null) {
      final theirNames = {
        for (final dev in remote.values)
          for (final l in dev.lists.values)
            if (!l.isDeleted) _fold(l.name?.value),
      };
      for (final row in await db.db.query('playlists', where: 'synced = 0')) {
        if (theirNames.contains(_fold('${row['name']}'))) await enable(row['id'] as int);
      }
      all = await states();
    }

    // Merge, on this device's states as they are now (the user may have
    // changed a list while the other devices' files came in), in one turn.
    final changed = <String>{};
    await _asSync(() async {
    all = await states();
    final fresh = await _set('sync2_fresh');
    final ignored = await _set('sync2_ignored');
    final ignoredBefore = ignored.length;
    for (final MapEntry(key: devId, value: dev) in remote.entries) {
      for (final MapEntry(key: sid, value: theirs) in dev.lists.entries) {
        if (sid == likedId && !await likedSynced) continue;
        final ours = all[sid];
        // First sync of a list turned on here: the other device's list of the same name is the same one.
        final link = ours != null
            ? null
            : fresh.where((f) => all[f] != null && !theirs.isDeleted && _fold(all[f]!.name?.value) == _fold(theirs.name?.value)).firstOrNull;
        if (ignored.contains(sid)) {
          // Sync stopped here: not brought back, unless the user turned it on again.
          if (link == null) continue;
          ignored.remove(sid);
        }
        if (ours != null) {
          final joined = _onceEach(ListState.join(ours, theirs), ours, theirs);
          if (_same(joined, ours)) continue;
          all[sid] = joined;
          changed.add(sid);
          _changedBy.putIfAbsent(sid, () => {}).add(devId);
          continue;
        }
        _changedBy.putIfAbsent(sid, () => {}).add(devId);
        if (link != null) {
          final have = {for (final e in theirs.shown) e.value.key};
          final mine0 = all.remove(link)!;
          final trimmed = ListState(items: {for (final e in mine0.items.entries) if (!have.contains(e.value.key)) e.key: e.value});
          all[sid] = ListState.join(theirs, trimmed);
          await db.db.update('playlists', {'uid': sid}, where: 'uid = ?', whereArgs: [link]);
          await _drop(link);
          fresh.remove(link);
          changed.add(sid);
        } else if (!theirs.isDeleted) {
          all[sid] = theirs;
          changed.add(sid);
        }
      }
    }
    if (remote.isNotEmpty) await _putSet('sync2_fresh', fresh..clear());
    if (ignored.length != ignoredBefore) await _putSet('sync2_ignored', ignored);
    for (final sid in changed) {
      await _save(sid, all[sid]!);
    }
    });

    // Song details first (a renamed song still matches its playlist entries).
    final s = await _settings();
    if (s['sync_edits'] != 'false') {
      final (out, got) = await _syncEdits(me, all, files);
      sent += out;
      received += got;
    }

    // Apply.
    final r = await _Resolver.make(db);
    final deleted = <String>[];
    var applied = 0;
    await _asSync(() async {
      // The states as they are now: a user change since the merge counts.
      final current = await states();
      for (final sid in changed) {
        final s = current[sid] ?? all[sid]!;
        all[sid] = s;
        if (!s.isDeleted) {
          if (await _apply(sid, s, r)) applied++;
          continue;
        }
        // Marked deleted by a version before 1.20.6: still here, so it stays
        // and goes back to the device that deleted it.
        final row = (await db.db.query('playlists', where: 'uid = ? AND synced = 1', whereArgs: [sid])).firstOrNull;
        if (row == null) continue;
        final back = ListState(name: s.name, deleted: Stamped(false, _clock(), me), items: s.items);
        await _save(sid, back);
        all[sid] = back;
        if (await _apply(sid, back, r)) applied++;
      }
    });
    if (applied > 0) db.notifyChanged();

    // What this device has of the synced playlists' songs.
    final have = <String>{};
    final lacking = <String>{};
    for (final s in all.values.where((s) => !s.isDeleted)) {
      for (final e in s.shown) {
        final t = r.real(e.value.song);
        (t != null ? have : lacking).add(e.value.key);
      }
    }
    final old = await _settings();
    for (final k in _oldMarks) {
      if (old.containsKey(k)) await db.db.delete('settings', where: 'key = ?', whereArgs: [k]);
    }
    final now = _clock();
    final content = {
      'lists': {for (final e in all.entries) e.key: e.value.pruned(now).toJson()},
      'have': have.toList(),
      'since': _since,
    };
    // Written only when something changed (once a day anyway, as a sign of
    // life): every write makes the other device sync, and it would answer.
    final mark = _canon(content);
    if (mark != _lastState || now - _stateAt > const Duration(days: 1).inMilliseconds) {
      await drive.upload(mine, utf8.encode(jsonEncode({'device': me, 'name': deviceName, 'updated': now, ...content})), id: byName[mine]?.id, mime: 'application/json');
      _lastState = mark;
      _stateAt = now;
    }
    await db.setSetting('sync2_sent_lists', jsonEncode(_listMarks(all)));
    received += applied;

    // Plays (statistics) both ways.
    if (s['sync_plays'] != 'false') {
      final (out, got) = await _syncPlays(me, files);
      sent += out;
      received += got;
    }

    // 外觀主題 (v1.16.0): the one chosen last, on every device that syncs it.
    if (s['sync_theme'] != 'false') {
      final (out, got) = await _syncTheme(me, files);
      sent += out;
      received += got;
    }

    // Songs: tidy the relay (checked against what is really on Drive), plan.
    await _cleanRelay(me, remote, all);
    _plan = await _planTransfers(me, all, remote, await drive.list(), r);
    final active = _activeOf(remote, now);
    // Still to come here: songs another device has (or that are on the relay).
    final owned = {for (final d in active) ...d.owns};
    final fetchable = _plan.any((t) => !t.upload) || lacking.any(owned.contains);
    // Still to go: songs here a device in use lacks.
    final waiting = active.any((d) => all.entries.any((e) => !e.value.isDeleted && e.value.shown.any((i) => have.contains(i.value.key) && d.lacks(e.key, i.value.key))));
    final incomplete = fetchable || waiting;
    _seen = seen;
    _changedBy.clear();
    await SyncLog.add(db, _logged);
    _logged.clear();
    return SyncResult(
      changed: applied,
      deleted: deleted,
      uploads: _plan.where((t) => t.upload).length,
      downloads: _plan.where((t) => !t.upload).length,
      incomplete: incomplete,
      sent: sent,
      received: received,
    );
  }

  String? _lastEdits, _lastPlays, _lastState, _lastTheme, _seen;

  /// When this install first synced: an older install of the same device
  /// (same name, silent since a newer one started) is no longer waited for.
  int _since = 0;

  /// The other devices still in use: synced within 30 days, and not an old
  /// install that a newer one of the same name replaced (the app removed and
  /// installed again leaves the old one's files on Drive).
  List<_Remote> _activeOf(Map<String, _Remote> remote, int now) {
    final starts = <(String?, int)>[(deviceName, _since), for (final d in remote.values) (d.name, d.since)];
    return [
      for (final d in remote.values)
        if (now - d.updated < _active.inMilliseconds && !starts.any((s) => s.$1 != null && s.$1 == d.name && s.$2 > d.updated)) d,
    ];
  }

  /// Which other devices changed each list in this sync (for 同步紀錄).
  final _changedBy = <String, Set<String>>{};

  /// The device a list's change came from, when only one changed it.
  String? _from(String sid) {
    final ids = _changedBy[sid];
    return ids != null && ids.length == 1 ? _deviceNames[ids.first] : null;
  }

  /// The same song added on two devices before they synced: kept once (the
  /// entry with the smaller id; the other is removed), the same way on both.
  /// Entries one device has twice on purpose are left alone.
  static ListState _onceEach(ListState joined, ListState a, ListState b) {
    Map<String, List<String>> newOn(ListState x, ListState y) {
      final out = <String, List<String>>{};
      for (final e in x.items.entries) {
        if (e.value.visible && !y.items.containsKey(e.key)) out.putIfAbsent(e.value.key, () => []).add(e.key);
      }
      return out;
    }

    final onA = newOn(a, b), onB = newOn(b, a);
    if (onA.isEmpty || onB.isEmpty) return joined;
    final items = Map.of(joined.items);
    var changed = false;
    for (final MapEntry(key: k, value: ids) in onA.entries) {
      final other = onB[k];
      if (other == null) continue;
      final xs = [...ids]..sort(), ys = [...other]..sort();
      for (var i = 0; i < min(xs.length, ys.length); i++) {
        final loser = xs[i].compareTo(ys[i]) > 0 ? xs[i] : ys[i];
        final at = max(items[xs[i]]!.addedAt, items[ys[i]]!.addedAt);
        items[loser] = items[loser]!.copyWith(removedAt: at);
        changed = true;
      }
    }
    return changed ? ListState(name: joined.name, deleted: joined.deleted, items: items) : joined;
  }

  /// Told when another device's theme was taken here (the app repaints).
  void Function()? onThemeChanged;

  /// The colour theme as `v2-prefs-<device>.json`: {'theme': {id, c, at,
  /// look}} from the settings color_theme / color_theme_custom /
  /// color_theme_at and the 外觀 choices ([Looks.keys], v1.17.0).
  Future<(int, int)> _syncTheme(String me, List<DriveFile> files) async {
    final s = await _settings();
    final at = int.tryParse(s['color_theme_at'] ?? '') ?? 0;
    final mine = {
      'id': s['color_theme'] ?? 'clear_sky',
      if (s['color_theme_custom'] != null) 'c': s['color_theme_custom'],
      'at': at,
      'look': {for (final k in Looks.keys) if (s[k] != null) k: s[k]},
    };
    final name = 'v2-prefs-$me.json';
    var sent = 0;
    final body = jsonEncode({'device': me, 'theme': mine});
    if (at > 0 && body != _lastTheme) {
      final file = files.where((f) => f.name == name).firstOrNull;
      String? before;
      if (file != null) {
        try {
          before = utf8.decode(await drive.download(file.id));
        } catch (_) {}
      }
      if (before != body) {
        await drive.upload(name, utf8.encode(body), id: file?.id, mime: 'application/json');
        sent = 1;
      }
      _lastTheme = body;
    }
    Map? newest;
    for (final f in files.where((f) => f.name.startsWith('v2-prefs-') && f.name != name)) {
      try {
        final t = (jsonDecode(utf8.decode(await drive.download(f.id))) as Map)['theme'];
        if (t is Map && t['id'] is String && ((t['at'] as num?)?.toInt() ?? 0) > ((newest?['at'] as num?)?.toInt() ?? at)) newest = t;
      } catch (_) {}
    }
    if (newest == null) return (sent, 0);
    await db.setSetting('color_theme', newest['id'] as String);
    if (newest['c'] is String) await db.setSetting('color_theme_custom', newest['c'] as String);
    final look = newest['look'];
    if (look is Map) {
      for (final k in Looks.keys) {
        if (look[k] is String) await db.setSetting(k, look[k] as String);
      }
    }
    await db.setSetting('color_theme_at', '${(newest['at'] as num).toInt()}');
    _lastTheme = null;
    onThemeChanged?.call();
    return (sent, 1);
  }
  int _stateAt = 0;

  /// The other devices' sync files as they are now.
  static String _signature(String me, List<DriveFile> files) => ([
        for (final f in files)
          if (RegExp(r'^v2-(state|edits|plays|relay|prefs)-').hasMatch(f.name) && !f.name.endsWith('-$me.json')) '${f.name}@${f.modified.millisecondsSinceEpoch}',
      ]..sort())
          .join('|');

  /// Whether another device wrote something since the last sync (one small
  /// file listing, for the check every minute).
  Future<bool> othersChanged() async => _signature(await deviceId(), await drive.list()) != _seen;

  static String _hash(Object? v) => sha256.convert(utf8.encode(_canon(v))).toString().substring(0, 8);

  /// A mark per name, deleted flag and entry of the lists, to tell what changed.
  static Map<String, String> _listMarks(Map<String, ListState> all) => {
        for (final e in all.entries) ...{
          '${e.key}|n': _hash(e.value.name?.toJson()),
          '${e.key}|d': _hash(e.value.deleted?.toJson()),
          for (final i in e.value.items.entries) '${e.key}|${i.key}': _hash(i.value.toJson()),
        },
      };

  /// Marks of what was last sent (null: nothing yet, so nothing counts as new).
  Future<Map<String, String>?> _marks(String key) async {
    final raw = (await _settings())[key];
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as Map).cast<String, String>();
    } catch (_) {
      return null;
    }
  }

  /// Song details and lyrics of the synced playlists' songs: this device's
  /// to Drive, the others' applied here; covers relayed.
  Future<(int, int)> _syncEdits(String me, Map<String, ListState> all, List<DriveFile> files) async {
    final synced = {for (final st in all.values.where((st) => !st.isDeleted)) for (final e in st.shown) e.value.key};
    final library = await db.tracks();
    await edits.adoptOldRenames((await _settings())['sync_names'], library, me);
    final covers = <String, File>{};
    final out = {...await edits.export(synced, library, covers), 'covers': await edits.coversHere()};
    // This device's own edits and its lyrics, as sent: what's new among them.
    final marks = {
      for (final e in (out['edits'] as Map).entries)
        if ((e.value as Map)['d'] == me) 'e|${e.key}': _hash(e.value),
      for (final e in (out['lyrics'] as Map).entries) 'l|${e.key}': _hash((e.value as Map)['l']),
    };
    final before = await _marks('sync2_sent_edits');
    final sent = before == null ? 0 : marks.entries.where((e) => before[e.key] != e.value).length;
    final name = 'v2-edits-$me.json';
    final body = jsonEncode(out);
    final mineFile = files.where((f) => f.name == name).firstOrNull;
    if (body != _lastEdits) {
      await drive.upload(name, utf8.encode(body), id: mineFile?.id, mime: 'application/json');
      _lastEdits = body;
    }
    final theirs = <Map>[];
    for (final f in files.where((f) => f.name.startsWith('v2-edits-') && f.name != name)) {
      try {
        theirs.add(jsonDecode(utf8.decode(await drive.download(f.id))) as Map);
      } catch (_) {}
    }
    final names = {for (final f in files) f.name: f.id};
    var received = 0;
    await _asSync(() async {
      received = await edits.apply(theirs, me, names);
      if (received > 0) db.notifyChanged();
    });
    // Lyrics that just came in aren't this device's to count next time.
    marks.addAll({for (final e in edits.adoptedLyrics.entries) 'l|${e.key}': _hash(e.value)});
    await db.setSetting('sync2_sent_edits', jsonEncode(marks));
    await edits.relayCovers(covers, [for (final t in theirs) {...((t['covers'] as List?) ?? const []).map((c) => '$c')}], files);
    return (sent, received);
  }

  /// This device's plays to Drive; the other devices' brought in.
  Future<(int, int)> _syncPlays(String me, List<DriveFile> files) async {
    final name = 'v2-plays-$me.json';
    final mine = await plays.export();
    final body = jsonEncode({'device': me, 'plays': mine});
    final last = int.tryParse((await _settings())['sync2_sent_play'] ?? '');
    final newest = mine.isEmpty ? (last ?? 0) : mine.last['id'] as int;
    final sent = last == null ? 0 : mine.where((p) => (p['id'] as int) > last).length;
    if (body != _lastPlays) {
      await drive.upload(name, utf8.encode(body), id: files.where((f) => f.name == name).firstOrNull?.id, mime: 'application/json');
      _lastPlays = body;
    }
    await db.setSetting('sync2_sent_play', '$newest');
    var received = 0;
    for (final f in files.where((f) => f.name.startsWith('v2-plays-') && f.name != name)) {
      try {
        final j = jsonDecode(utf8.decode(await drive.download(f.id))) as Map;
        received += await plays.import('${j['device']}', (j['plays'] as List?) ?? const []);
      } catch (_) {}
    }
    return (sent, received);
  }

  static String _fold(String? s) => (s ?? '').trim().toLowerCase();

  static bool _same(ListState a, ListState b) => _canon(a.toJson()) == _canon(b.toJson());

  static String _canon(Object? v) {
    Object? sort(Object? x) => x is Map
        ? {for (final k in (x.keys.map((k) => '$k').toList()..sort())) k: sort(x[k])}
        : x is List
            ? [for (final e in x) sort(e)]
            : x;
    return jsonEncode(sort(v));
  }

  // ---------- songs through the relay ----------

  List<_Transfer> _plan = [];
  bool paused = false;
  CancelToken? _token;
  bool _running = false;

  /// Relay indexes: device → song key → meta.
  Future<Map<String, Map<String, Map>>> _indexes(List<DriveFile> files) async {
    final out = <String, Map<String, Map>>{};
    for (final f in files.where((f) => f.name.startsWith('v2-relay-'))) {
      final dev = f.name.substring('v2-relay-'.length, f.name.length - '.json'.length);
      try {
        out[dev] = (jsonDecode(utf8.decode(await drive.download(f.id))) as Map).map((k, v) => MapEntry('$k', v as Map));
      } catch (_) {}
    }
    return out;
  }

  Future<List<_Transfer>> _planTransfers(
      String me, Map<String, ListState> all, Map<String, _Remote> remote, List<DriveFile> files, _Resolver r) async {
    final now = _clock();
    final others = _activeOf(remote, now);
    final indexes = await _indexes(files);
    final onDrive = {for (final f in files) f.name};
    // Only songs whose file really is on Drive.
    final onRelay = <String, (String, Map)>{
      for (final e in indexes.entries)
        for (final m in e.value.entries)
          if (onDrive.contains('${m.value['file']}')) m.key: (e.key, m.value),
    };
    final out = <String, _Transfer>{};
    for (final MapEntry(key: sid, value: s) in all.entries) {
      if (s.isDeleted) continue;
      for (final e in s.shown) {
        final key = e.value.key;
        if (out.containsKey(key)) continue;
        final t = r.real(e.value.song);
        if (t != null) {
          if (!onRelay.containsKey(key) && others.any((d) => d.lacks(sid, key))) out[key] = _Transfer.up(key, t);
        } else if (onRelay[key] case (final dev, final meta) when dev != me) {
          out[key] = _Transfer.down(key, meta);
        }
      }
    }
    return [...out.values];
  }

  /// This device's relay index made to match Drive: songs every other device
  /// has now are removed, entries whose file is gone are dropped (so the song
  /// goes up again). Song files no index lists (left by an interrupted
  /// upload) are removed after a day.
  Future<void> _cleanRelay(String me, Map<String, _Remote> remote, Map<String, ListState> all) => _locked(() async {
        // Listed now (inside the lock): an upload that just finished is in it.
        final files = await drive.list();
        final now = _clock();
        final others = _activeOf(remote, now);
        final listsOf = <String, Set<String>>{};
        for (final e in all.entries) {
          if (e.value.isDeleted) continue;
          for (final i in e.value.shown) {
            listsOf.putIfAbsent(i.value.key, () => {}).add(e.key);
          }
        }
        // Kept while a device in use still lacks it.
        bool needed(String key) => others.any((d) => d.lacks('', key) || (listsOf[key] ?? const {}).any((sid) => d.lacks(sid, key)));
        final indexName = 'v2-relay-$me.json';
        final indexFile = files.where((f) => f.name == indexName).firstOrNull;
        final names = {for (final f in files) f.name: f.id};
        final index = indexFile == null
            ? <String, Map>{}
            : (jsonDecode(utf8.decode(await drive.download(indexFile.id))) as Map).map((k, v) => MapEntry('$k', v as Map));
        var dropped = false;
        final unused = <String>{};
        for (final key in [...index.keys]) {
          final m = index[key]!;
          final gone = !names.containsKey('${m['file']}');
          if (!gone && needed(key)) continue;
          index.remove(key);
          unused.addAll(['${m['file']}', '${m['art']}']);
          dropped = true;
        }
        // The same file can be listed under two names (each device's).
        for (final m in index.values) {
          unused.removeAll(['${m['file']}', '${m['art']}']);
        }
        for (final n in unused) {
          final id = names[n];
          if (id != null) await drive.delete(id);
        }
        if (dropped) await drive.upload(indexName, utf8.encode(jsonEncode(index)), id: indexFile!.id, mime: 'application/json');
        // Files of no index, a day old: nobody is going to fetch them.
        final listed = <String>{};
        for (final m in (await _indexes(files)).entries) {
          for (final e in (m.key == me ? index : m.value).values) {
            listed
              ..add('${e['file']}')
              ..add('${e['art']}');
          }
        }
        for (final f in files) {
          if (!(f.name.startsWith('v2-song-') || f.name.startsWith('v2-art-')) || listed.contains(f.name)) continue;
          if (DateTime.now().difference(f.modified) < const Duration(days: 1)) continue;
          await drive.delete(f.id);
        }
      });

  /// Songs planned by the last [sync], one at a time. [onProgress] gets null
  /// when done. Stops on [pause].
  Future<int> runTransfers({required int relayCap, void Function(TransferProgress? p)? onProgress}) async {
    if (_running) return 0;
    _running = true;
    var done = 0;
    try {
      final me = await deviceId();
      final plan = [..._plan];
      for (var i = 0; i < plan.length; i++) {
        if (paused) break;
        final t = plan[i];
        void progress(int sent, int total) => onProgress?.call(TransferProgress(
            done: i, total: plan.length, title: t.title, upload: t.upload, fraction: total > 0 ? sent / total : 0, paused: paused));
        progress(0, 0);
        for (var attempt = 0; attempt < 3; attempt++) {
          if (paused) break;
          _token = CancelToken();
          try {
            if (t.upload) {
              final full = !await _upload(me, t.key, t.track!, relayCap, progress);
              if (full) {
                onProgress?.call(TransferProgress(done: i, total: plan.length, title: t.title, upload: true, fraction: 0, full: true));
                return done;
              }
            } else {
              await _download(t.key, t.meta!, progress);
            }
            _plan.remove(t);
            done++;
            break;
          } on DioException catch (e) {
            if (e.type.name == 'cancel') break;
          } catch (_) {}
          await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
        }
      }
    } finally {
      _running = false;
      _token = null;
      onProgress?.call(null);
    }
    return done;
  }

  /// 暫停: stops this round (the song on its way starts over later). Songs
  /// still missing are planned again by the syncs after [resume].
  void pause() {
    paused = true;
    _token?.cancel();
  }

  void resume() => paused = false;

  bool get transfersRunning => _running;
  int get pending => _plan.length;

  /// Up to the relay (false: it's full). Its meta goes into this device's
  /// index under [key], the name the playlist knows it by (1.20.6: the
  /// song's name here can differ, e.g. original vs romaji).
  Future<bool> _upload(String me, String key, Track t, int cap, void Function(int, int) progress) async {
    final file = File(t.uri);
    final size = await file.length();
    final files = await drive.list();
    final indexes = await _indexes(files);
    final used = indexes.values.expand((m) => m.values).fold<int>(0, (a, m) => a + ((m['size'] as num?)?.toInt() ?? 0));
    if (used + size > cap) return false;
    final sha = (await sha256.bind(file.openRead()).first).toString();
    final ext = p.extension(t.uri);
    final name = 'v2-song-$sha$ext';
    if (!files.any((f) => f.name == name)) {
      await drive.uploadFile(name, file, mime: 'application/octet-stream', onProgress: progress, cancel: _token);
    }
    String? art;
    final cover = t.art;
    if (cover != null && !cover.startsWith('http') && File(cover).existsSync()) {
      art = 'v2-art-$sha';
      await drive.upload(art, await File(cover).readAsBytes(), mime: 'image/jpeg');
    }
    final indexName = 'v2-relay-$me.json';
    await _locked(() async {
      final fresh = await drive.list();
      final indexFile = fresh.where((f) => f.name == indexName).firstOrNull;
      final index = indexFile == null ? <String, Object?>{} : (jsonDecode(utf8.decode(await drive.download(indexFile.id))) as Map).cast<String, Object?>();
      index[key] = {
        't': t.title, 'a': t.artist, 'al': t.album, 'ms': t.durationMs, 'size': size, 'sha': sha, 'file': name, if (art != null) 'art': art,
      };
      await drive.upload(indexName, utf8.encode(jsonEncode(index)), id: indexFile?.id, mime: 'application/json');
    });
    return true;
  }

  /// From the relay into the download folder, checked against its SHA-256,
  /// with the sender's names and cover; it then fills the greyed entries,
  /// those of the playlist's name for it ([key]) too.
  Future<void> _download(String key, Map meta, void Function(int, int) progress) async {
    final files = {for (final f in await drive.list()) f.name: f.id};
    final id = files['${meta['file']}'];
    if (id == null) throw StateError('not on Drive');
    final dir = downloadDir();
    await Directory(dir).create(recursive: true);
    // Unfinished file in the app's own temp folder: Android lets only audio
    // files into the music folders, so a .part there can't even be created.
    final part = p.join(Directory.systemTemp.path, 'ouo-sync-${meta['sha']}.part');
    try {
      await drive.downloadTo(id, part, onProgress: progress, cancel: _token);
      final sha = (await sha256.bind(File(part).openRead()).first).toString();
      if (sha != meta['sha']) throw StateError('checksum');
      final path = _freePath(dir, '${meta['a']} - ${meta['t']}', p.extension('${meta['file']}'));
      try {
        await File(part).rename(path);
      } on FileSystemException {
        // Another filesystem (app temp → shared storage): copy instead.
        await File(part).copy(path);
      }
      final imported = await importFile(path);
      if (imported == null) return;
      var cover = imported.art;
      final artId = files['${meta['art']}'];
      if (artId != null) cover = await storeArt(await drive.download(artId), 'image/jpeg');
      final named = Track(
        id: imported.id,
        uri: imported.uri,
        title: '${meta['t']}',
        artist: '${meta['a']}',
        album: '${meta['al'] ?? imported.album}',
        durationMs: imported.durationMs,
        art: cover,
        source: imported.source,
        trackNo: imported.trackNo,
        addedAt: imported.addedAt,
      );
      await _asSync(() async {
        await db.updateTrackInfo(named);
        await MissingSongs.fillExact(db, named, listedAs: key);
        await MissingSongs.adoptPlays(db, named);
        // Listed under another name (romaji here, the original there): the
        // song is known by that name from now on, as if renamed from it.
        if (key != songKey(named.title, named.artist)) {
          await db.db.insert(
              'track_edits',
              {
                'track_id': named.id, 'root': key, 'root_ms': meta['ms'] ?? named.durationMs, 'title': named.title, 'artist': named.artist,
                'album': named.album, 'at': 1, 'device': await deviceId(),
              },
              conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      });
    } finally {
      final f = File(part);
      if (f.existsSync()) await f.delete();
    }
  }

  static String _freePath(String dir, String name, String ext) {
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    var path = p.join(dir, '$safe$ext');
    for (var i = 2; File(path).existsSync(); i++) {
      path = p.join(dir, '$safe ($i)$ext');
    }
    return path;
  }
}

class _Remote {
  _Remote(this.name, this.updated, this.owns, this.lists, {this.since = 0});
  final String? name;
  final int updated;

  /// When that install first synced.
  final int since;

  /// Songs it has.
  final Set<String> owns;
  final Map<String, ListState> lists;

  late final Set<String> _listed = {
    for (final l in lists.values)
      if (!l.isDeleted)
        for (final e in l.shown) e.value.key,
  };

  bool syncs(String sid) => lists[sid] != null && !lists[sid]!.isDeleted;

  /// It lacks [key] of this device's list [sid]: it syncs that list (or
  /// already lists the song) and doesn't have the song. A list it doesn't
  /// sync (stopped, likes off) is no reason to send songs.
  bool lacks(String sid, String key) => !owns.contains(key) && (syncs(sid) || _listed.contains(key));
}

class _Transfer {
  _Transfer.up(this.key, Track this.track) : meta = null;
  _Transfer.down(this.key, Map this.meta) : track = null;
  final String key;
  final Track? track;
  final Map? meta;
  bool get upload => track != null;
  String get title => track?.title ?? '${meta!['t']}';
}

/// Finds this device's song for a synced entry (the song comparator), or a
/// greyed placeholder.
class _Resolver {
  /// With the songs renamed here known by their first names too (roots).
  static Future<_Resolver> make(AppDatabase db) async {
    final library = await db.tracks();
    final r = _Resolver(db, library);
    final byId = {for (final t in library) t.id: t};
    for (final row in await db.db.query('track_edits')) {
      final t = byId[row['track_id']];
      if (t != null && t.uri.isNotEmpty) r._exact.putIfAbsent('${row['root']}', () => []).add(t);
    }
    return r;
  }

  _Resolver(this.db, List<Track> library)
      : _matcher = LibraryMatcher(library),
        _holes = {for (final t in library.where((t) => t.source == TrackSource.missing)) songKey(t.title, t.artist): t} {
    for (final t in library.where((t) => t.source != TrackSource.missing && t.uri.isNotEmpty)) {
      _exact.putIfAbsent(songKey(t.title, t.artist), () => []).add(t);
    }
  }
  final AppDatabase db;
  final LibraryMatcher _matcher;
  final Map<String, Track> _holes;
  final _exact = <String, List<Track>>{};

  /// Same title and artist (and length within 3 s) first, then the comparator.
  Track? _find(Map song) {
    final ms = song['ms'] as int?;
    final same = _exact[songKey('${song['t']}', '${song['a']}')]
        ?.where((t) => ms == null || t.durationMs == null || (t.durationMs! - ms).abs() <= 3000)
        .firstOrNull;
    return same ?? _matcher.find('', title: '${song['t']}', artist: '${song['a']}', durationMs: ms);
  }

  Track? real(Map song) {
    final t = _find(song);
    return t != null && !t.isRemote && File(t.uri).existsSync() ? t : null;
  }

  Future<Track> resolve(Map song) async {
    final found = _find(song);
    if (found != null) return found;
    final key = songKey('${song['t']}', '${song['a']}');
    return _holes[key] ??= await MissingSongs.create(db, '${song['t']}', '${song['a']}', album: '${song['al'] ?? ''}', durationMs: song['ms'] as int?);
  }
}
