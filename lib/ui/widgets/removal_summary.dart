import 'package:flutter/material.dart';

import '../../data/db/database.dart';

/// The 「從以下地方移除」 lines of a delete/hide warning: library, each
/// playlist (and how many times), likes, the queue, and the albums and
/// artists that will be left empty.
List<String> describeRemoval(RemovalImpact impact, {required int songs, int inQueue = 0}) {
  String times(int n) => songs == 1 ? (n > 1 ? '（$n 次）' : '') : '（$n 首）';
  String names(List<String> l) => l.length <= 3 ? l.map((n) => '「$n」').join('、') : '${l.take(3).map((n) => '「$n」').join('、')} 等 ${l.length} 個';
  return [
    '音樂庫',
    if (impact.playlists.isNotEmpty) '播放清單：${impact.playlists.entries.map((e) => '「${e.key}」${times(e.value)}').join('、')}',
    if (impact.favorites > 0) '已按讚的歌曲${songs == 1 ? '' : '（${impact.favorites} 首）'}',
    if (inQueue > 0) '目前的播放佇列${songs == 1 ? '' : '（$inQueue 首）'}',
    if (impact.emptyAlbums.isNotEmpty) '專輯 ${names(impact.emptyAlbums)}（只剩這些歌，會一起消失）',
    if (impact.emptyArtists.isNotEmpty) '演出者 ${names(impact.emptyArtists)}（只剩這些歌，會一起消失）',
  ];
}

/// The lines as a bulleted list for a dialog.
class RemovalList extends StatelessWidget {
  const RemovalList(this.lines, {super.key});
  final List<String> lines;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('• '), Expanded(child: Text(l))]),
          ),
      ]);
}
