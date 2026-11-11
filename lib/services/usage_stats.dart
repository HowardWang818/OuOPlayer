import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';

import '../config/demo.dart';
import '../config/update_config.dart';
import '../config/version.dart';
import '../data/db/database.dart';

/// 匿名使用人數統計: once a day, a random id (made here, tied to nothing),
/// the version and the platform go to the update server, which counts how
/// many different ids it saw each day (docs/PRIVACY.md).
class UsageStats {
  static const onKey = 'usage_stats';
  static const idKey = 'usage_id';
  static const dayKey = 'usage_day';

  /// A fresh random id: 16 hex characters.
  static String newId([Random? r]) {
    final rnd = r ?? Random.secure();
    return List.generate(16, (_) => rnd.nextInt(16).toRadixString(16)).join();
  }

  /// The headers /hello takes.
  static Map<String, String> headers(String id) => {
        ...updateHeaders,
        'x-ouo-id': id,
        'x-ouo-ver': appVersion,
        'x-ouo-platform': Platform.isAndroid ? 'android' : 'windows',
      };

  static String _today(DateTime now) => '${now.year}-${now.month}-${now.day}';

  /// Whether today's count is still to be sent (on, not sent today).
  static bool due(Map<String, String> settings, DateTime now) =>
      settings[onKey] != 'false' && settings[dayKey] != _today(now);

  /// Sends today's count if it is due. Never throws.
  static Future<void> sendIfDue(AppDatabase db, {Dio? dio, DateTime? now}) async {
    if (isDemo || !(Platform.isAndroid || Platform.isWindows)) return;
    try {
      final s = await db.allSettings();
      final t = now ?? DateTime.now();
      if (!due(s, t)) return;
      var id = s[idKey] ?? '';
      if (id.length != 16) {
        id = newId();
        await db.setSetting(idKey, id);
      }
      await (dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 15))))
          .get<void>('$updateServer/hello', options: Options(headers: headers(id)));
      await db.setSetting(dayKey, _today(t));
    } catch (_) {}
  }
}
