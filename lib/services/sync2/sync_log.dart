import 'dart:convert';

import '../../data/db/database.dart';

/// One change sync brought in from another device.
class SyncLogEntry {
  const SyncLogEntry(this.at, this.text, {this.device});
  final DateTime at;
  final String text;

  /// The device it came from, when known.
  final String? device;

  Map<String, Object?> toJson() => {'at': at.millisecondsSinceEpoch, 't': text, if (device != null) 'd': device};

  factory SyncLogEntry.fromJson(Map m) =>
      SyncLogEntry(DateTime.fromMillisecondsSinceEpoch((m['at'] as num).toInt()), '${m['t']}', device: m['d'] as String?);
}

/// 同步紀錄: the latest [keep] changes applied from other devices (playlist
/// songs added and removed, likes, names and covers), newest first.
class SyncLog {
  static const key = 'sync_log';
  static const keep = 100;

  static Future<List<SyncLogEntry>> read(AppDatabase db) async {
    try {
      return [for (final m in jsonDecode((await db.allSettings())[key] ?? '[]') as List) SyncLogEntry.fromJson(m as Map)];
    } catch (_) {
      return [];
    }
  }

  static Future<void> add(AppDatabase db, List<SyncLogEntry> entries) async {
    if (entries.isEmpty) return;
    final all = [...entries.reversed, ...await read(db)];
    await db.setSetting(key, jsonEncode([for (final e in all.take(keep)) e.toJson()]));
  }
}
