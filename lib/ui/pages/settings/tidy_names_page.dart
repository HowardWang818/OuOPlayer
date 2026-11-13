import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../data/models/track.dart';
import '../../../providers/providers.dart';
import '../../../services/file_names.dart';
import '../../widgets/dialogs.dart';

/// 整理檔名 (1.20.5): the songs in the download folder whose file name isn't
/// their official name (iTunes, else their name in the app) are listed, then
/// renamed after one tap. iTunes answers about 20 searches a minute.
class TidyNamesPage extends ConsumerStatefulWidget {
  const TidyNamesPage({super.key});

  @override
  ConsumerState<TidyNamesPage> createState() => _TidyNamesPageState();
}

class _TidyNamesPageState extends ConsumerState<TidyNamesPage> {
  final _changes = <(Track, String)>[];
  int _checked = 0, _total = 0;
  bool _looking = true, _renaming = false, _stop = false;

  @override
  void initState() {
    super.initState();
    _look();
  }

  @override
  void dispose() {
    _stop = true;
    super.dispose();
  }

  Future<void> _look() async {
    final dir = ref.read(settingsProvider).downloadDir;
    final songs = [
      for (final t in await ref.read(dbProvider).tracks())
        if (t.uri.isNotEmpty && p.isWithin(dir, t.uri)) t,
    ];
    if (!mounted) return;
    setState(() => _total = songs.length);
    final itunes = ref.read(iTunesSearchProvider);
    for (final t in songs) {
      if (_stop) return;
      final name = await FileNames.nameFor(t, itunes);
      final target = FileNames.targetFor(t, name);
      if (!mounted) return;
      setState(() {
        _checked++;
        if (target != t.uri) _changes.add((t, name));
      });
      // iTunes allows about 20 searches a minute.
      await Future.delayed(const Duration(seconds: 3));
    }
    if (mounted) setState(() => _looking = false);
  }

  Future<void> _rename() async {
    setState(() => _renaming = true);
    final db = ref.read(dbProvider);
    var done = 0;
    for (final (t, name) in [..._changes]) {
      final after = await FileNames.rename(db, t, name);
      if (after.uri != t.uri) done++;
    }
    if (!mounted) return;
    toast(context, '已改名 $done 個檔案');
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: const Text('整理檔名')),
      body: Column(children: [
        if (_looking) ...[
          LinearProgressIndicator(value: _total == 0 ? null : _checked / _total),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('正在查詢 $_checked / $_total', style: TextStyle(color: muted)),
          ),
        ] else
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_changes.isEmpty ? '檔名都已整理好' : '${_changes.length} 個檔名要改', style: TextStyle(color: muted)),
          ),
        Expanded(
          child: ListView(children: [
            for (final (t, name) in _changes)
              ListTile(
                dense: true,
                title: Text(p.basename(FileNames.targetFor(t, name)), maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(p.basename(t.uri), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: muted)),
              ),
          ]),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _looking || _renaming || _changes.isEmpty ? null : _rename,
                child: Text(_renaming ? '改名中…' : '改名'),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
