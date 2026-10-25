import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../services/listening_stats.dart';
import '../../theme/app_theme.dart';
import '../widgets/art_image.dart';
import '../widgets/artist_avatar.dart';
import '../widgets/dialogs.dart';
import 'collection_page.dart';
import 'year_review_page.dart';

/// Listening statistics for a period, from the listening log.
final statsProvider = FutureProvider.family<ListeningStats, StatsPeriod>((ref, period) async {
  ref.watch(dbRevisionProvider);
  final db = ref.watch(dbProvider);
  final (from, to) = period.range(DateTime.now());
  final log = await db.listening(from, to);
  final library = {for (final t in await db.tracks()) t.id: t};
  return ListeningStats.compute(log, library);
});

class _PeriodNotifier extends Notifier<StatsPeriod> {
  @override
  StatsPeriod build() => StatsPeriod.month;
  void set(StatsPeriod p) => state = p;
}

final _periodProvider = NotifierProvider<_PeriodNotifier, StatsPeriod>(_PeriodNotifier.new);

class StatsPage extends ConsumerWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final period = ref.watch(_periodProvider);
    final stats = ref.watch(statsProvider(period));
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: const Text('收聽統計')),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Wrap(spacing: 8, children: [
            for (final p in StatsPeriod.values)
              ChoiceChip(
                label: Text(p.label),
                selected: p == period,
                showCheckmark: false,
                labelStyle: TextStyle(color: p == period ? Colors.black : null),
                onSelected: (_) => ref.read(_periodProvider.notifier).set(p),
              ),
          ]),
        ),
        if (period == StatsPeriod.year)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: FilledButton.icon(
              icon: const Icon(Icons.auto_awesome),
              label: Text('我的 ${DateTime.now().year} 回顧'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const YearReviewPage())),
            ),
          ),
        ...stats.when(
          loading: () => const [Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()))],
          error: (e, _) => [Padding(padding: const EdgeInsets.all(24), child: Text('讀取失敗：$e'))],
          data: (s) => s.isEmpty
              ? [Padding(padding: const EdgeInsets.all(48), child: Center(child: Text('這段期間還沒有收聽紀錄', style: TextStyle(color: muted))))]
              : _sections(context, ref, s, period),
        ),
      ]),
    );
  }

  List<Widget> _sections(BuildContext context, WidgetRef ref, ListeningStats s, StatsPeriod period) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    Widget tile(String label, String value) => Expanded(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: TextStyle(color: muted, fontSize: 12)),
                const SizedBox(height: 4),
                Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ]),
            ),
          ),
        );
    Widget header(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(t, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
        );
    final handler = ref.read(audioHandlerProvider);
    final topTracks = [for (final t in s.topTracks) t.track];
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [tile('收聽時間', formatListening(s.music)), tile('播放次數', '${s.plays} 次'), tile('不同的歌', '${s.distinctSongs} 首')]),
      ),
      if (s.podcasts > Duration.zero)
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Text('另外聽了 Podcast ${formatListening(s.podcasts)}', style: TextStyle(color: muted))),
      if (s.hasEstimates)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text('部分為估計值：v0.12.0 以前的紀錄用歌曲長度計算', style: TextStyle(color: muted, fontSize: 12)),
        ),
      if (period == StatsPeriod.week || period == StatsPeriod.month) ...[
        header('每天收聽時間'),
        _DailyChart(stats: s, period: period),
      ],
      if (s.topTracks.isNotEmpty) ...[
        Row(children: [
          Expanded(child: header('最常聽的歌')),
          Padding(
            padding: const EdgeInsets.only(top: 16, right: 8),
            child: TextButton.icon(
              icon: const Icon(Icons.playlist_add),
              label: const Text('存成播放清單'),
              onPressed: () async {
                final db = ref.read(dbProvider);
                final name = '${period.label}最常聽 Top ${topTracks.length}';
                final id = await db.createPlaylist(name);
                await db.addToPlaylist(id, topTracks);
                if (context.mounted) toast(context, '已建立「$name」');
              },
            ),
          ),
        ]),
        for (var i = 0; i < s.topTracks.length; i++)
          ListTile(
            leading: SizedBox(
              width: 88,
              child: Row(children: [
                SizedBox(width: 28, child: Text('${i + 1}', style: const TextStyle(fontWeight: FontWeight.bold))),
                ArtImage(s.topTracks[i].track.art, size: 48),
              ]),
            ),
            title: Text(s.topTracks[i].track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${s.topTracks[i].track.artist} • ${s.topTracks[i].plays} 次', maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => handler.playTracks(topTracks, index: i),
          ),
      ],
      if (s.topArtists.isNotEmpty) ...[
        header('最常聽的歌手'),
        for (final a in s.topArtists)
          ListTile(
            leading: ArtistAvatar(Artist(a.name, a.art, 0), size: 48),
            title: Text(a.name),
            subtitle: Text('${a.plays} 次 • ${formatListening(a.listened)}'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CollectionPage.artist(a.name))),
          ),
      ],
    ];
  }
}

/// Bars per day (simple, no chart package).
class _DailyChart extends StatelessWidget {
  const _DailyChart({required this.stats, required this.period});
  final ListeningStats stats;
  final StatsPeriod period;

  @override
  Widget build(BuildContext context) {
    final (from, to) = period.range(DateTime.now());
    final days = <DateTime>[
      for (var d = from; d.isBefore(to); d = DateTime(d.year, d.month, d.day + 1)) d,
    ];
    final values = [for (final d in days) stats.daily[d] ?? Duration.zero];
    final maxMs = values.fold<int>(1, (m, v) => v.inMilliseconds > m ? v.inMilliseconds : m);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        height: 140,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (var i = 0; i < days.length; i++)
            Expanded(
              child: Tooltip(
                message: '${days[i].month}/${days[i].day}：${formatListening(values[i])}',
                child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                  Container(
                    height: 110 * values[i].inMilliseconds / maxMs + 2,
                    margin: const EdgeInsets.symmetric(horizontal: 1.5),
                    decoration: BoxDecoration(
                      color: values[i] == Duration.zero ? muted.withValues(alpha: 0.2) : AppColors.accent,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    period == StatsPeriod.week ? '一二三四五六日'[days[i].weekday - 1] : (days[i].day % 5 == 1 ? '${days[i].day}' : ''),
                    style: TextStyle(fontSize: 10, color: muted),
                  ),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Used by the year review too.
List<Track> topTracksOf(ListeningStats s) => [for (final t in s.topTracks) t.track];
