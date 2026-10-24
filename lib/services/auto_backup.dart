import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/db/database.dart';
import 'backup.dart';

enum BackupFrequency {
  daily('每天'),
  weekly('每週'),
  monthly('每月');

  const BackupFrequency(this.label);
  final String label;
}

/// When automatic backups happen.
class BackupSchedule {
  const BackupSchedule({
    this.enabled = false,
    this.frequency = BackupFrequency.weekly,
    this.weekdays = const {DateTime.sunday},
    this.monthDay = 1,
    this.hour = 3,
    this.minute = 0,
  });

  final bool enabled;
  final BackupFrequency frequency;

  /// For [BackupFrequency.weekly]: DateTime.monday … DateTime.sunday.
  final Set<int> weekdays;

  /// For [BackupFrequency.monthly]: 1–31; months without that day use their last day.
  final int monthDay;
  final int hour;
  final int minute;

  bool _isDay(DateTime d) => switch (frequency) {
        BackupFrequency.daily => true,
        BackupFrequency.weekly => weekdays.contains(d.weekday),
        BackupFrequency.monthly => d.day == min(monthDay, DateTime(d.year, d.month + 1, 0).day),
      };

  DateTime _at(DateTime day) => DateTime(day.year, day.month, day.day, hour, minute);

  /// The latest backup time at or before [now] (null if none in the last ~2 months).
  DateTime? lastDue(DateTime now) {
    for (var i = 0; i <= 62; i++) {
      final day = DateTime(now.year, now.month, now.day - i);
      if (_isDay(day) && !_at(day).isAfter(now)) return _at(day);
    }
    return null;
  }

  /// The next backup time after [now].
  DateTime? nextDue(DateTime now) {
    for (var i = 0; i <= 62; i++) {
      final day = DateTime(now.year, now.month, now.day + i);
      if (_isDay(day) && _at(day).isAfter(now)) return _at(day);
    }
    return null;
  }

  /// Whether a backup is owed: a backup time passed since [last].
  bool isDue(DateTime now, DateTime? last) {
    if (!enabled) return false;
    final due = lastDue(now);
    return due != null && (last == null || last.isBefore(due));
  }

  BackupSchedule copyWith({bool? enabled, BackupFrequency? frequency, Set<int>? weekdays, int? monthDay, int? hour, int? minute}) =>
      BackupSchedule(
        enabled: enabled ?? this.enabled,
        frequency: frequency ?? this.frequency,
        weekdays: weekdays ?? this.weekdays,
        monthDay: monthDay ?? this.monthDay,
        hour: hour ?? this.hour,
        minute: minute ?? this.minute,
      );

  String encode() => jsonEncode({
        'enabled': enabled,
        'frequency': frequency.name,
        'weekdays': (weekdays.toList()..sort()),
        'month_day': monthDay,
        'hour': hour,
        'minute': minute,
      });

  static BackupSchedule decode(String? s) {
    try {
      final m = (jsonDecode(s ?? '') as Map).cast<String, Object?>();
      final days = {for (final d in (m['weekdays'] as List? ?? const [])) if (d is int && d >= 1 && d <= 7) d};
      return BackupSchedule(
        enabled: m['enabled'] == true,
        frequency: BackupFrequency.values.firstWhere((f) => f.name == m['frequency'], orElse: () => BackupFrequency.weekly),
        weekdays: days.isEmpty ? const {DateTime.sunday} : days,
        monthDay: ((m['month_day'] as int?) ?? 1).clamp(1, 31),
        hour: ((m['hour'] as int?) ?? 3).clamp(0, 23),
        minute: ((m['minute'] as int?) ?? 0).clamp(0, 59),
      );
    } catch (_) {
      return const BackupSchedule();
    }
  }
}

/// One backup file in the backup folder.
class BackupFile {
  BackupFile(this.path, this.time, this.bytes, {required this.automatic});
  final String path;
  final DateTime time;
  final int bytes;
  final bool automatic;
}

/// Automatic backups: written into a folder the user can see (and copy
/// elsewhere), the newest [keep] kept.
class AutoBackup {
  static const prefix = 'OuOPlayer自動備份_';
  static const keep = 10;

  /// Documents/OuOPlayer/備份 on the phone and on Windows.
  static Future<String> defaultDir() async {
    if (Platform.isAndroid) return '/storage/emulated/0/Documents/OuOPlayer/備份';
    if (Platform.isWindows) return p.join(Platform.environment['USERPROFILE'] ?? '', 'Documents', 'OuOPlayer', '備份');
    return p.join((await getApplicationDocumentsDirectory()).path, 'OuOPlayer', '備份');
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String fileName(DateTime d) => '$prefix${d.year}-${_two(d.month)}-${_two(d.day)}_${_two(d.hour)}${_two(d.minute)}${_two(d.second)}.json';

  /// Writes a backup now and removes automatic ones beyond the newest [keep].
  static Future<File> run(AppDatabase db, String dir, {DateTime? now}) async {
    final d = Directory(dir);
    await d.create(recursive: true);
    final data = await buildBackup(db);
    final file = File(p.join(dir, fileName(now ?? DateTime.now())));
    await file.writeAsString(const JsonEncoder.withIndent(' ').convert(data));
    await prune(dir);
    return file;
  }

  /// Only automatic backups are removed; ones the user saved stay.
  static Future<void> prune(String dir) async {
    final auto = [
      for (final f in Directory(dir).listSync().whereType<File>())
        if (p.basename(f.path).startsWith(prefix) && f.path.endsWith('.json')) f,
    ]..sort((a, b) => p.basename(b.path).compareTo(p.basename(a.path)));
    for (final f in auto.skip(keep)) {
      try {
        await f.delete();
      } catch (_) {}
    }
  }

  /// The OuOPlayer backups in [dir], newest first.
  static Future<List<BackupFile>> list(String dir) async {
    final d = Directory(dir);
    if (!await d.exists()) return const [];
    final out = <BackupFile>[];
    await for (final f in d.list(followLinks: false)) {
      final name = p.basename(f.path);
      if (f is! File || !name.endsWith('.json') || !name.startsWith('OuOPlayer')) continue;
      try {
        final stat = await f.stat();
        out.add(BackupFile(f.path, stat.modified, stat.size, automatic: name.startsWith(prefix)));
      } catch (_) {}
    }
    out.sort((a, b) => b.time.compareTo(a.time));
    return out;
  }
}
