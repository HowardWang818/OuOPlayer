import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/demo.dart';
import '../config/update_config.dart';
import '../config/version.dart';
import '../data/db/database.dart';
import '../providers/providers.dart';
import '../ui/pages/settings/section_page.dart';

/// 匿名使用人數統計: once a day, a random id (made here, tied to nothing),
/// the version and the platform go to the update server, which counts how
/// many different ids it saw each day. Off with the switch in 關於與更新.
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

/// The switch in 關於與更新. Turning it off also forgets the id.
final usageStatsOnProvider = NotifierProvider<UsageStatsOn, bool>(UsageStatsOn.new);

class UsageStatsOn extends Notifier<bool> {
  @override
  bool build() {
    ref.read(dbProvider).allSettings().then((s) => state = s[UsageStats.onKey] != 'false');
    return true;
  }

  Future<void> set(bool on) async {
    state = on;
    final db = ref.read(dbProvider);
    await db.setSetting(UsageStats.onKey, '$on');
    if (!on) await db.setSetting(UsageStats.idKey, '');
  }
}

class UsageStatsSwitch extends ConsumerWidget {
  const UsageStatsSwitch({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => SettingSwitch(
        secondary: const Icon(Icons.insights_outlined),
        title: const Text('匿名使用人數統計'),
        subtitle: const Text('每天一次送出隨機代碼、版本和平台，只用來知道大約多少人在用；不含任何個人資料。關掉後代碼也會刪除'),
        value: ref.watch(usageStatsOnProvider),
        onChanged: ref.read(usageStatsOnProvider.notifier).set,
      );
}
