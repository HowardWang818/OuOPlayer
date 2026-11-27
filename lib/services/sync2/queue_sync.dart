import 'dart:convert';

import '../../data/db/database.dart';
import '../list_queues.dart';
import '../sync/drive_client.dart';

/// 1.24.0: the synced lists' own queues (ListQueue) on every device, in each
/// device's `v2-queues-<device>.json`. The last action (a song, a pause, a
/// shuffle) wins; seconds aren't sent. Replaces 接續播放's `v2-now-*`.
class QueueSync {
  QueueSync({required this.db, required this.drive, required this.deviceId, required this.queues});

  final AppDatabase db;
  final DriveStore drive;
  final Future<String> Function() deviceId;
  final ListQueues queues;

  String? _myId;
  String? _sent;
  bool _cleaned = false;

  /// The list keys here ↔ their ids in sync (a playlist's uid; 'liked').
  Future<Map<String, String>> _synced() async {
    final out = <String, String>{};
    for (final r in await db.db.query('playlists', columns: ['id', 'uid'], where: 'synced = 1 AND uid IS NOT NULL')) {
      out[ListQueues.keyFor(r['id'] as int)] = '${r['uid']}';
    }
    if ((await db.allSettings())['sync_liked'] == 'true') out[ListQueues.favorites] = 'liked';
    return out;
  }

  /// This device's queues of synced lists up (when they changed), the other
  /// devices' newer ones taken. Returns how many were taken.
  Future<int> run() async {
    await queues.ready;
    final me = await deviceId();
    final name = 'v2-queues-$me.json';
    final files = await drive.list();
    final synced = await _synced();
    final bySid = {for (final e in synced.entries) e.value: e.key};

    // The others first: what is taken here then goes up as it is now.
    var taken = 0;
    for (final f in files.where((f) => f.name.startsWith('v2-queues-') && f.name != name)) {
      try {
        final j = jsonDecode(utf8.decode(await drive.download(f.id))) as Map;
        for (final e in ((j['lists'] as Map?) ?? const {}).entries) {
          final key = bySid['${e.key}'];
          if (key == null) continue;
          final theirs = ListQueue.fromJson(e.value as Map);
          if (!theirs.newerThan(queues[key])) continue;
          await queues.adopt(key, theirs);
          taken++;
        }
      } catch (_) {}
    }

    final lists = {
      for (final e in synced.entries)
        if (queues[e.key] != null && queues[e.key]!.order.isNotEmpty) e.value: queues[e.key]!.toSync(),
    };
    final body = jsonEncode({'device': me, 'lists': lists});
    if (body != _sent) {
      _myId ??= files.where((f) => f.name == name).firstOrNull?.id;
      try {
        _myId = await drive.upload(name, utf8.encode(body), id: _myId, mime: 'application/json');
      } catch (_) {
        // Removed meanwhile: a new one.
        _myId = await drive.upload(name, utf8.encode(body), mime: 'application/json');
      }
      _sent = body;
    }

    // 接續播放 is gone (1.24.0): this device's file of it goes once.
    if (!_cleaned) {
      for (final f in files.where((f) => f.name == 'v2-now-$me.json')) {
        try {
          await drive.delete(f.id);
        } catch (_) {}
      }
      _cleaned = true;
    }
    return taken;
  }
}
