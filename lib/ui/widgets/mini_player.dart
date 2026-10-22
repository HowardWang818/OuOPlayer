import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../../theme/app_theme.dart';
import '../pages/now_playing_page.dart';
import '../pages/queue_page.dart';
import 'art_image.dart';
import 'output_device_chip.dart';
import 'player_controls.dart';

void openNowPlaying(BuildContext context) => Navigator.of(context, rootNavigator: true).push(PageRouteBuilder(
      pageBuilder: (_, __, ___) => const NowPlayingPage(),
      transitionsBuilder: (_, a, __, child) => SlideTransition(
        position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
        child: child,
      ),
    ));

/// Phone layout: floating card above the bottom navigation bar.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    if (track == null) return const SizedBox.shrink();
    final color = ref.watch(artColorProvider(track.art)).value ?? Theme.of(context).colorScheme.surfaceContainerHigh;
    // Pick readable text/icons for whatever colour the cover (or theme) gives us.
    final fg = ThemeData.estimateBrightnessForColor(color) == Brightness.dark ? Colors.white : Colors.black87;
    final pos = ref.watch(positionProvider).value ?? Duration.zero;
    final dur = ref.watch(durationProvider).value;
    final progress = dur == null || dur.inMilliseconds == 0 ? 0.0 : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
    final handler = ref.read(audioHandlerProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => openNowPlaying(context),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(children: [
                ArtImage(track.art, size: 42),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: FontWeight.w600, color: fg)),
                    Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: fg.withValues(alpha: 0.7))),
                  ]),
                ),
                OutputDeviceChip(dense: true, color: fg),
                IconTheme(data: IconThemeData(color: fg), child: FavoriteButton(activeColor: fg)),
                IconTheme(
                  data: IconThemeData(color: fg),
                  child: const PlayPauseButton(size: 40, filled: false),
                ),
                IconButton(icon: Icon(Icons.skip_next, color: fg), onPressed: handler.skipToNext),
              ]),
            ),
            LinearProgressIndicator(value: progress, minHeight: 2, backgroundColor: fg.withValues(alpha: 0.24), color: fg),
          ]),
        ),
      ),
    );
  }
}

/// Desktop layout: Spotify-style bottom control bar.
class DesktopPlayerBar extends ConsumerWidget {
  const DesktopPlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 88,
      color: cs.surfaceContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        Expanded(
          flex: 3,
          child: track == null
              ? const SizedBox()
              : InkWell(
                  onTap: () => openNowPlaying(context),
                  child: Row(children: [
                    ArtImage(track.art, size: 56),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                        Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                      ]),
                    ),
                    const FavoriteButton(),
                  ]),
                ),
        ),
        const Expanded(
          flex: 4,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            TransportControls(big: false),
            SeekBar(compact: true),
          ]),
        ),
        Expanded(
          flex: 3,
          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            IconButton(
              tooltip: '佇列',
              icon: const Icon(Icons.queue_music),
              onPressed: () => Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => const QueuePage())),
            ),
            const OutputDeviceChip(dense: true),
            const VolumeSlider(),
          ]),
        ),
      ]),
    );
  }
}

class AccentDot extends StatelessWidget {
  const AccentDot({super.key});
  @override
  Widget build(BuildContext context) =>
      Container(width: 6, height: 6, decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle));
}
