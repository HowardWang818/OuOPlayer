import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/auto_backup.dart';
import 'providers.dart';

class AutoBackupState {
  const AutoBackupState({this.schedule = const BackupSchedule(), this.dir = '', this.last, this.error, this.running = false, this.loaded = false});
  final BackupSchedule schedule;
  final String dir;
  final DateTime? last;

  /// Why the latest automatic backup failed (cleared by the next success).
  final String? error;
  final bool running;
  final bool loaded;

  AutoBackupState copyWith({BackupSchedule? schedule, String? dir, DateTime? last, String? error, bool clearError = false, bool? running, bool? loaded}) =>
      AutoBackupState(
        schedule: schedule ?? this.schedule,
        dir: dir ?? this.dir,
        last: last ?? this.last,
        error: clearError ? null : error ?? this.error,
        running: running ?? this.running,
        loaded: loaded ?? this.loaded,
      );
}

/// Runs backups on the chosen schedule while OuOPlayer is running; a backup
/// time missed while it was closed is made up the next time it opens.
final autoBackupProvider = NotifierProvider<AutoBackupNotifier, AutoBackupState>(AutoBackupNotifier.new);

class AutoBackupNotifier extends Notifier<AutoBackupState> {
  Timer? _timer;
  AppLifecycleListener? _lifecycle;

  @override
  AutoBackupState build() {
    ref.onDispose(() {
      _timer?.cancel();
      _lifecycle?.dispose();
    });
    _lifecycle = AppLifecycleListener(onResume: _check);
    Future.microtask(_load);
    return const AutoBackupState();
  }

  Future<void> _load() async {
    final m = await ref.read(dbProvider).allSettings();
    final dir = m['auto_backup_dir'];
    state = state.copyWith(
      schedule: BackupSchedule.decode(m['auto_backup']),
      dir: dir == null || dir.isEmpty ? await AutoBackup.defaultDir() : dir,
      last: DateTime.tryParse(m['auto_backup_last'] ?? ''),
      loaded: true,
    );
    await _check();
  }

  Future<void> _check() async {
    _timer?.cancel();
    if (!state.loaded) return;
    final s = state.schedule;
    if (s.isDue(DateTime.now(), state.last)) await backupNow();
    final next = s.enabled ? s.nextDue(DateTime.now()) : null;
    if (next != null) _timer = Timer(next.difference(DateTime.now()) + const Duration(seconds: 1), _check);
  }

  /// Writes a backup into the backup folder now. Returns the error, if any.
  Future<String?> backupNow() async {
    if (state.running) return null;
    state = state.copyWith(running: true);
    try {
      await AutoBackup.run(ref.read(dbProvider), state.dir);
      final now = DateTime.now();
      await ref.read(dbProvider).setSetting('auto_backup_last', now.toIso8601String());
      state = state.copyWith(last: now, running: false, clearError: true);
      return null;
    } catch (e) {
      final msg = '無法寫入「${state.dir}」：$e';
      state = state.copyWith(running: false, error: msg);
      return msg;
    }
  }

  Future<void> setSchedule(BackupSchedule s) async {
    state = state.copyWith(schedule: s);
    await ref.read(dbProvider).setSetting('auto_backup', s.encode());
    // The first time it is turned on, the first backup is made right away.
    await _check();
  }

  /// [dir] null goes back to the default folder.
  Future<void> setDir(String? dir) async {
    state = state.copyWith(dir: dir ?? await AutoBackup.defaultDir());
    await ref.read(dbProvider).setSetting('auto_backup_dir', dir ?? '');
  }
}
