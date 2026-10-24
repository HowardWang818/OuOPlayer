import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../../services/listening_stats.dart';
import '../../theme/app_theme.dart';
import '../widgets/art_image.dart';
import 'stats_page.dart';

/// 我的年度回顧: swipeable cards coloured after the year's top cover.
class YearReviewPage extends ConsumerStatefulWidget {
  const YearReviewPage({super.key});

  @override
  ConsumerState<YearReviewPage> createState() => _YearReviewPageState();
}

class _YearReviewPageState extends ConsumerState<YearReviewPage> {
  final _pages = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final year = DateTime.now().year;
    final stats = ref.watch(statsProvider(StatsPeriod.year));
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.transparent, foregroundColor: Colors.white, title: Text('我的 $year 回顧')),
      body: stats.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('讀取失敗：$e', style: const TextStyle(color: Colors.white))),
        data: (s) {
          if (s.isEmpty) {
            return const Center(child: Text('今年還沒有收聽紀錄', style: TextStyle(color: Colors.white70)));
          }
          final top = s.topTracks.firstOrNull;
          final color = ref.watch(artColorProvider(top?.track.art)).value ?? AppColors.accent.withValues(alpha: 0.6);
          final cards = <Widget>[
            _Card(color: color, children: [
              const Text('今年你總共聽了', style: TextStyle(fontSize: 20)),
              const SizedBox(height: 12),
              Text('${s.music.inHours}', style: const TextStyle(fontSize: 88, fontWeight: FontWeight.w900)),
              const Text('小時的音樂', style: TextStyle(fontSize: 22)),
              const SizedBox(height: 16),
              Text('${s.plays} 次播放 • ${s.distinctSongs} 首不同的歌', style: const TextStyle(fontSize: 16)),
            ]),
            if (top != null)
              _Card(color: color, children: [
                const Text('你的年度歌曲', style: TextStyle(fontSize: 20)),
                const SizedBox(height: 20),
                ArtImage(top.track.art, size: 220, radius: 12),
                const SizedBox(height: 20),
                Text(top.track.title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
                Text(top.track.artist, style: const TextStyle(fontSize: 18)),
                const SizedBox(height: 8),
                Text('聽了 ${top.plays} 次', style: const TextStyle(fontSize: 16)),
              ]),
            if (s.topArtists.isNotEmpty)
              _Card(color: color, children: [
                const Text('你的年度歌手', style: TextStyle(fontSize: 20)),
                const SizedBox(height: 20),
                ArtImage(s.topArtists.first.art, size: 200, circle: true, icon: Icons.person),
                const SizedBox(height: 20),
                Text(s.topArtists.first.name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
                Text('${s.topArtists.first.plays} 次 • ${formatListening(s.topArtists.first.listened)}', style: const TextStyle(fontSize: 16)),
              ]),
            if (s.busiestMonth != null || s.favouriteDayPart != null)
              _Card(color: color, children: [
                if (s.busiestMonth != null) ...[
                  const Text('聽最多音樂的月份', style: TextStyle(fontSize: 20)),
                  Text('${s.busiestMonth} 月', style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w900)),
                  Text(formatListening(s.monthly[s.busiestMonth]!), style: const TextStyle(fontSize: 16)),
                  const SizedBox(height: 32),
                ],
                if (s.favouriteDayPart != null) ...[
                  const Text('你最常在', style: TextStyle(fontSize: 20)),
                  Text(s.favouriteDayPart!.label, style: const TextStyle(fontSize: 56, fontWeight: FontWeight.w900)),
                  const Text('聽音樂', style: TextStyle(fontSize: 20)),
                ],
              ]),
            if (s.topTracks.isNotEmpty)
              _Card(color: color, children: [
                const Text('今年的 Top 5', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                for (var i = 0; i < s.topTracks.length && i < 5; i++)
                  ListTile(
                    textColor: Colors.white,
                    leading: SizedBox(
                      width: 84,
                      child: Row(children: [
                        SizedBox(width: 28, child: Text('${i + 1}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
                        ArtImage(s.topTracks[i].track.art, size: 48),
                      ]),
                    ),
                    title: Text(s.topTracks[i].track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(s.topTracks[i].track.artist, maxLines: 1, style: const TextStyle(color: Colors.white70)),
                  ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('播放年度歌曲'),
                  onPressed: () => ref.read(audioHandlerProvider).playTracks(topTracksOf(s)),
                ),
              ]),
          ];
          return Column(children: [
            Expanded(
              child: PageView(controller: _pages, onPageChanged: (i) => setState(() => _page = i), children: cards),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (var i = 0; i < cards.length; i++)
                  Container(
                    width: i == _page ? 18 : 8,
                    height: 8,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(color: i == _page ? Colors.white : Colors.white38, borderRadius: BorderRadius.circular(4)),
                  ),
              ]),
            ),
            if (s.hasEstimates)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text('部分為估計值', style: TextStyle(color: Colors.white54, fontSize: 12)),
              ),
          ]);
        },
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.color, required this.children});
  final Color color;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [color, Colors.black]),
        ),
        child: DefaultTextStyle(
          style: const TextStyle(color: Colors.white),
          textAlign: TextAlign.center,
          child: Center(child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: children))),
        ),
      );
}
