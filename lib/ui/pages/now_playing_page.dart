import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../theme/app_theme.dart';
import '../widgets/art_image.dart';
import '../widgets/image_viewer.dart';
import '../widgets/lyrics_view.dart';
import '../widgets/output_device_chip.dart';
import '../widgets/player_controls.dart';
import '../widgets/sleep_timer_sheet.dart';
import '../widgets/track_links.dart';
import '../widgets/track_tile.dart';
import 'queue_page.dart';

class NowPlayingPage extends ConsumerWidget {
  const NowPlayingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    final theme = Theme.of(context);
    final bg = theme.scaffoldBackgroundColor;
    // A song without a cover gets a gradient in the app's colour.
    final noCover = track != null && (track.art == null || track.art!.isEmpty);
    final color = noCover
        ? Color.alphaBlend(AppColors.accent.withValues(alpha: 0.55), bg)
        : ref.watch(artColorProvider(track?.art)).value ?? theme.colorScheme.surfaceContainerHigh;
    final wide = MediaQuery.sizeOf(context).width > 900;
    // What is behind the lyrics (the gradient a third of the way down) and
    // behind the top bar (the cover's colour).
    final lyricsBg = Color.lerp(color, bg, wide ? 0.45 : 0.35)!;
    final topInk = ThemeData.estimateBrightnessForColor(color) == Brightness.dark ? Colors.white : const Color(0xFF111111);
    final showLyrics = ref.watch(showLyricsProvider);

    final cover = LayoutBuilder(builder: (context, c) {
      final size = c.maxWidth.clamp(120.0, 520.0);
      return Center(
        child: Container(
          decoration: BoxDecoration(boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 30, offset: const Offset(0, 12))]),
          child: ZoomableArt(art: track?.art, child: ArtImage(track?.art, size: size, radius: 8)),
        ),
      );
    });

    final info = Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(track?.title ?? '沒有播放中的歌曲',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            // The artist and the album (top bar) open their pages.
            LinkText(track?.artist ?? '',
                onTap: track != null && hasPages(track) ? () => openArtist(context, track) : null,
                style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ]),
        ),
        const FavoriteButton(),
      ]),
      const SizedBox(height: 16),
      const SeekBar(),
      const SizedBox(height: 8),
      const TransportControls(),
      if (track?.source == TrackSource.podcast) const PodcastControls(),
      const SizedBox(height: 8),
      Row(children: [
        const Expanded(child: OutputDeviceChip()),
        IconButton(
          tooltip: '歌詞',
          isSelected: showLyrics,
          icon: const Icon(Icons.lyrics_outlined),
          selectedIcon: const Icon(Icons.lyrics),
          onPressed: ref.read(showLyricsProvider.notifier).toggle,
        ),
        const SleepTimerButton(),
        IconButton(
          tooltip: '佇列',
          icon: const Icon(Icons.queue_music),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const QueuePage())),
        ),
      ]),
    ]);

    return Scaffold(
      body: AnimatedContainer(
        duration: const Duration(milliseconds: 500),
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [color, bg], stops: const [0, 0.85]),
        ),
        child: SafeArea(
          child: Column(children: [
            // The top bar sits on the cover's colour itself.
            IconTheme.merge(
              data: IconThemeData(color: topInk),
              child: DefaultTextStyle.merge(
              style: TextStyle(color: topInk),
              child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(children: [
                IconButton(icon: const Icon(Icons.keyboard_arrow_down, size: 32), color: topInk, onPressed: () => Navigator.pop(context)),
                Expanded(
                  child: Column(children: [
                    Text('正在播放', style: theme.textTheme.labelSmall?.copyWith(color: topInk)),
                    LinkText(track?.album ?? '',
                        onTap: track != null && hasPages(track) ? () => openAlbum(context, track) : null,
                        style: TextStyle(fontWeight: FontWeight.bold, color: topInk)),
                  ]),
                ),
                IconButton(
                  icon: const Icon(Icons.more_vert),
                  color: topInk,
                  onPressed: track == null ? null : () => showTrackMenu(context, ref, track),
                ),
              ]),
            ))),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: wide
                    ? Row(children: [
                        Expanded(child: cover),
                        const SizedBox(width: 48),
                        Expanded(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: info))),
                        // Desktop: lyrics in a panel on the right.
                        if (showLyrics) ...[const SizedBox(width: 48), Expanded(child: LyricsInk.on(lyricsBg, child: const LyricsView()))],
                      ])
                    : Column(children: [
                        // Phone: lyrics take the cover's place.
                        Expanded(child: showLyrics ? LyricsInk.on(lyricsBg, child: const LyricsView()) : cover),
                        const SizedBox(height: 24),
                        info,
                      ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Rewind / speed / forward row, shown only while a podcast is playing.
class PodcastControls extends ConsumerWidget {
  const PodcastControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final handler = ref.read(audioHandlerProvider);
    final next = podcastSpeeds[(podcastSpeeds.indexOf(s.podcastSpeed) + 1) % podcastSpeeds.length];
    return Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
      TextButton.icon(
        onPressed: () => handler.seekBy(-s.seekSeconds),
        icon: const Icon(Icons.replay),
        label: Text('${s.seekSeconds} 秒'),
      ),
      OutlinedButton(
        onPressed: () => ref.read(settingsProvider.notifier).setPodcastSpeed(next),
        child: Text('${s.podcastSpeed}x'),
      ),
      TextButton.icon(
        onPressed: () => handler.seekBy(s.seekSeconds),
        // Mirrored replay arrow, so forward and rewind look like a pair.
        icon: Transform.flip(flipX: true, child: const Icon(Icons.replay)),
        label: Text('${s.seekSeconds} 秒'),
      ),
    ]);
  }
}
