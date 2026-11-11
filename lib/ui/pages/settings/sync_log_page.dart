import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';
import '../../../services/sync2/sync_log.dart';
import '../../widgets/empty_state.dart';

/// 同步紀錄: what sync brought in from the other devices, newest first.
class SyncLogPage extends ConsumerWidget {
  const SyncLogPage({super.key});

  static String _when(DateTime d) =>
      '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(dbRevisionProvider);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: const Text('同步紀錄')),
      body: FutureBuilder<List<SyncLogEntry>>(
        future: SyncLog.read(ref.read(dbProvider)),
        builder: (_, snap) {
          final list = snap.data ?? const <SyncLogEntry>[];
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (list.isEmpty) return const EmptyState(icon: Icons.sync_rounded, title: '尚無同步紀錄');
          return ListView.builder(
            itemCount: list.length,
            itemBuilder: (_, i) {
              final e = list[i];
              return ListTile(
                dense: true,
                title: Text(e.text),
                subtitle: Text([_when(e.at), if (e.device != null) e.device!].join(' • '), style: TextStyle(color: muted)),
              );
            },
          );
        },
      ),
    );
  }
}
