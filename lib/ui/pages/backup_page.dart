import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auto_backup_provider.dart';
import '../../services/auto_backup.dart';
import '../../services/storage_usage.dart';
import '../widgets/backup_actions.dart';
import '../widgets/dialogs.dart';

const _weekdayNames = {
  DateTime.monday: '一',
  DateTime.tuesday: '二',
  DateTime.wednesday: '三',
  DateTime.thursday: '四',
  DateTime.friday: '五',
  DateTime.saturday: '六',
  DateTime.sunday: '日',
};

String _when(DateTime d) =>
    '${d.year}/${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// 備份與還原: manual export / import, the automatic backup schedule and
/// folder, and the backups in that folder to restore from.
class BackupPage extends ConsumerStatefulWidget {
  const BackupPage({super.key});

  @override
  ConsumerState<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends ConsumerState<BackupPage> {
  Future<List<BackupFile>>? _files;
  String? _listed;

  void _refresh(String dir) {
    _listed = dir;
    _files = AutoBackup.list(dir);
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(autoBackupProvider);
    final n = ref.read(autoBackupProvider.notifier);
    final s = st.schedule;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    if (st.loaded && _listed != st.dir) _refresh(st.dir);
    // A new backup appears in the list.
    ref.listen(autoBackupProvider.select((x) => x.last), (_, __) => setState(() => _refresh(st.dir)));
    final next = s.enabled ? s.nextDue(DateTime.now()) : null;

    Widget header(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(t, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('備份與還原')),
      body: !st.loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: [
              header('手動'),
              ListTile(
                leading: const Icon(Icons.backup_outlined),
                title: const Text('備份資料'),
                subtitle: const Text('播放清單、資料夾、已按讚的歌曲、播放次數、Podcast 和設定，存成一個檔案（不含 YouTube 金鑰）'),
                onTap: () => exportBackup(context, ref),
              ),
              ListTile(
                leading: const Icon(Icons.file_open_outlined),
                title: const Text('從檔案還原'),
                subtitle: const Text('選一個備份檔。會取代目前的資料，還原前會先確認'),
                onTap: () => importBackup(context, ref),
              ),
              header('自動備份'),
              SwitchListTile(
                secondary: const Icon(Icons.schedule),
                title: const Text('自動備份'),
                subtitle: Text(s.enabled
                    ? (next == null ? '已開啟' : '下次備份：${_when(next)}')
                    : '開啟後會照下面的時間自動備份到備份資料夾'),
                value: s.enabled,
                onChanged: (v) => n.setSchedule(s.copyWith(enabled: v)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: SegmentedButton<BackupFrequency>(
                  segments: [for (final f in BackupFrequency.values) ButtonSegment(value: f, label: Text(f.label))],
                  selected: {s.frequency},
                  onSelectionChanged: (v) => n.setSchedule(s.copyWith(frequency: v.first)),
                ),
              ),
              if (s.frequency == BackupFrequency.weekly)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(spacing: 6, children: [
                    for (final e in _weekdayNames.entries)
                      FilterChip(
                        label: Text('週${e.value}'),
                        selected: s.weekdays.contains(e.key),
                        onSelected: (on) {
                          final days = {...s.weekdays};
                          on ? days.add(e.key) : days.remove(e.key);
                          if (days.isEmpty) {
                            toast(context, '至少要選一天');
                            return;
                          }
                          n.setSchedule(s.copyWith(weekdays: days));
                        },
                      ),
                  ]),
                ),
              if (s.frequency == BackupFrequency.monthly)
                ListTile(
                  leading: const Icon(Icons.calendar_month_outlined),
                  title: const Text('每月的哪一天'),
                  subtitle: Text(s.monthDay > 28 ? '沒有 ${s.monthDay} 號的月份，會在那個月的最後一天備份' : '每月 ${s.monthDay} 號',
                      style: TextStyle(color: muted)),
                  trailing: DropdownButton<int>(
                    value: s.monthDay,
                    items: [for (var d = 1; d <= 31; d++) DropdownMenuItem(value: d, child: Text('$d 號'))],
                    onChanged: (v) => n.setSchedule(s.copyWith(monthDay: v)),
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.access_time),
                title: const Text('時間'),
                subtitle: Text('${s.hour.toString().padLeft(2, '0')}:${s.minute.toString().padLeft(2, '0')}'),
                onTap: () async {
                  final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: s.hour, minute: s.minute));
                  if (t != null) await n.setSchedule(s.copyWith(hour: t.hour, minute: t.minute));
                },
              ),
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('備份資料夾'),
                subtitle: Text(st.dir, style: TextStyle(color: muted)),
                trailing: FutureBuilder<String>(
                  future: AutoBackup.defaultDir(),
                  builder: (_, snap) => snap.data == null || snap.data == st.dir
                      ? const SizedBox.shrink()
                      : TextButton(onPressed: () => n.setDir(null), child: const Text('改回預設')),
                ),
                onTap: () async {
                  final d = await FilePicker.getDirectoryPath(dialogTitle: '選擇備份資料夾');
                  if (d != null) await n.setDir(d);
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
                child: Text(
                  '自動備份最多保留最新的 ${AutoBackup.keep} 份，較舊的自動刪除；手動存的備份不會被刪。\n'
                  'OuOPlayer 沒有在執行時錯過的備份，會在下次打開時補做。',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ),
              ListTile(
                leading: st.running
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save_outlined),
                title: const Text('立即備份到備份資料夾'),
                subtitle: Text(
                  [
                    if (st.last != null) '上次備份：${_when(st.last!)}',
                    if (st.error != null) '上次失敗：${st.error}',
                  ].join('\n').ifEmpty('還沒有備份過'),
                  style: TextStyle(color: st.error != null ? Theme.of(context).colorScheme.error : muted),
                ),
                onTap: st.running
                    ? null
                    : () async {
                        final err = await n.backupNow();
                        if (context.mounted) toast(context, err ?? '已備份');
                      },
              ),
              header('備份資料夾裡的備份'),
              FutureBuilder<List<BackupFile>>(
                future: _files,
                builder: (context, snap) {
                  final files = snap.data ?? const [];
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
                  }
                  if (files.isEmpty) {
                    return Padding(padding: const EdgeInsets.all(16), child: Text('這個資料夾裡還沒有備份', style: TextStyle(color: muted)));
                  }
                  return Column(children: [
                    for (final f in files)
                      ListTile(
                        leading: Icon(f.automatic ? Icons.history : Icons.description_outlined),
                        title: Text(_when(f.time)),
                        subtitle: Text('${f.automatic ? '自動備份' : '手動備份'} • ${formatBytes(f.bytes)}', style: TextStyle(color: muted)),
                        trailing: const Icon(Icons.settings_backup_restore),
                        onTap: () => restoreFromFile(context, ref, f.path),
                      ),
                  ]);
                },
              ),
              const SizedBox(height: 24),
            ]),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
