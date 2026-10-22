import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/download_service.dart';
import '../widgets/dialogs.dart';
import '../widgets/track_tile.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _ctrl = TextEditingController();
  String _q = '';

  bool get _isUrl => _q.startsWith('http://') || _q.startsWith('https://');

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final results = _isUrl ? const <Track>[] : (ref.watch(searchProvider(_q)).value ?? const <Track>[]);
    final handler = ref.read(audioHandlerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('搜尋')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            controller: _ctrl,
            onChanged: (v) => setState(() => _q = v.trim()),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: '想聽什麼？（或貼上音樂 / 串流網址）',
              suffixIcon: _q.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _ctrl.clear();
                        setState(() => _q = '');
                      },
                    ),
            ),
          ),
        ),
        Expanded(
          child: _isUrl
              ? ListView(children: [
                  ListTile(
                    leading: const Icon(Icons.play_circle_outline),
                    title: const Text('串流播放此網址'),
                    subtitle: Text(_q, maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => handler.playTracks([Track.fromUrl(_q)]),
                  ),
                  ListTile(
                    leading: const Icon(Icons.download),
                    title: const Text('下載到本機'),
                    subtitle: const Text('直連檔案直接下載，其他網址交給 yt-dlp'),
                    onTap: () {
                      final svc = ref.read(downloadServiceProvider);
                      svc.add(_q, format: ref.read(settingsProvider).ytFormat);
                      toast(context, '已加入下載佇列');
                      ref.read(tabProvider.notifier).set(3);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.file_download_outlined),
                    title: const Text('以直接下載方式下載'),
                    onTap: () {
                      ref.read(downloadServiceProvider).add(_q, kind: DownloadKind.direct);
                      toast(context, '已加入下載佇列');
                    },
                  ),
                ])
              : _q.isEmpty
                  ? Center(child: Text('搜尋歌曲、演出者或專輯', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)))
                  : results.isEmpty
                      ? const Center(child: Text('找不到結果'))
                      : ListView.builder(
                          itemCount: results.length,
                          itemBuilder: (_, i) => TrackTile(track: results[i], onTap: () => handler.playTracks(results, index: i)),
                        ),
        ),
      ]),
    );
  }
}
