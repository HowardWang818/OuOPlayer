import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import '../../theme/app_theme.dart';
import 'art_image.dart';

class SeekBar extends ConsumerStatefulWidget {
  const SeekBar({super.key, this.compact = false});
  final bool compact;

  @override
  ConsumerState<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends ConsumerState<SeekBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final pos = ref.watch(positionProvider).value ?? Duration.zero;
    final dur = ref.watch(durationProvider).value ?? Duration.zero;
    final max = dur.inMilliseconds.toDouble();
    final value = (_drag ?? pos.inMilliseconds.toDouble()).clamp(0.0, max <= 0 ? 1.0 : max);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final slider = Slider(
      value: value,
      max: max <= 0 ? 1 : max,
      onChanged: max <= 0 ? null : (v) => setState(() => _drag = v),
      onChangeEnd: (v) {
        ref.read(audioHandlerProvider).seek(Duration(milliseconds: v.round()));
        setState(() => _drag = null);
      },
    );
    final left = Text(formatDuration(Duration(milliseconds: value.round())), style: TextStyle(fontSize: 11, color: muted));
    final right = Text(formatDuration(dur), style: TextStyle(fontSize: 11, color: muted));
    if (widget.compact) {
      return Row(children: [left, const SizedBox(width: 8), Expanded(child: slider), const SizedBox(width: 8), right]);
    }
    return Column(children: [
      slider,
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [left, right]),
      ),
    ]);
  }
}

class PlayPauseButton extends ConsumerWidget {
  const PlayPauseButton({super.key, this.size = 56, this.filled = true});
  final double size;
  final bool filled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playbackStateProvider).value;
    final playing = state?.playing ?? false;
    final loading = state?.processingState == AudioProcessingState.loading || state?.processingState == AudioProcessingState.buffering;
    final handler = ref.read(audioHandlerProvider);
    final icon = Icon(playing ? Icons.pause : Icons.play_arrow, size: size * 0.55);
    if (!filled) {
      return IconButton(iconSize: size * 0.7, onPressed: playing ? handler.pause : handler.play, icon: icon);
    }
    final onBg = Theme.of(context).colorScheme.onSurface;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(alignment: Alignment.center, children: [
        if (loading) SizedBox(width: size, height: size, child: const CircularProgressIndicator(strokeWidth: 2)),
        IconButton.filled(
          style: IconButton.styleFrom(backgroundColor: onBg, foregroundColor: Theme.of(context).scaffoldBackgroundColor, fixedSize: Size(size, size)),
          onPressed: playing ? handler.pause : handler.play,
          icon: icon,
        ),
      ]),
    );
  }
}

class TransportControls extends ConsumerWidget {
  const TransportControls({super.key, this.big = true});
  final bool big;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final handler = ref.read(audioHandlerProvider);
    final shuffle = ref.watch(shuffleProvider).value ?? false;
    final loop = ref.watch(loopModeProvider).value ?? LoopMode.off;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final iconSize = big ? 36.0 : 24.0;
    return Row(mainAxisAlignment: big ? MainAxisAlignment.spaceBetween : MainAxisAlignment.center, children: [
      IconButton(
        tooltip: '隨機播放',
        icon: Icon(Icons.shuffle, color: shuffle ? AppColors.accent : muted),
        onPressed: handler.toggleShuffle,
      ),
      IconButton(iconSize: iconSize, tooltip: '上一首', icon: const Icon(Icons.skip_previous), onPressed: handler.skipToPrevious),
      PlayPauseButton(size: big ? 68 : 36),
      IconButton(iconSize: iconSize, tooltip: '下一首', icon: const Icon(Icons.skip_next), onPressed: handler.skipToNext),
      IconButton(
        tooltip: '重複播放',
        icon: Icon(loop == LoopMode.one ? Icons.repeat_one : Icons.repeat, color: loop == LoopMode.off ? muted : AppColors.accent),
        onPressed: handler.cycleRepeat,
      ),
    ]);
  }
}

class FavoriteButton extends ConsumerWidget {
  const FavoriteButton({super.key, this.activeColor});

  /// Colour of the filled heart; defaults to the accent colour.
  final Color? activeColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    if (track == null) return const SizedBox.shrink();
    final fav = ref.watch(favoriteIdsProvider).value?.contains(track.id) ?? false;
    return IconButton(
      tooltip: fav ? '從已按讚的歌曲移除' : '加到已按讚的歌曲',
      icon: Icon(fav ? Icons.favorite : Icons.favorite_border, color: fav ? (activeColor ?? AppColors.accent) : null),
      onPressed: () => ref.read(dbProvider).setFavorite(track, !fav),
    );
  }
}

class VolumeSlider extends ConsumerWidget {
  const VolumeSlider({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The user's volume, not the player's (which moves during fades).
    final v = ref.watch(volumeProvider).value ?? 1;
    final handler = ref.read(audioHandlerProvider);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        icon: Icon(v == 0 ? Icons.volume_off : (v < 0.5 ? Icons.volume_down : Icons.volume_up), size: 20),
        onPressed: () => handler.setUserVolume(v == 0 ? 1 : 0),
      ),
      SizedBox(width: 110, child: Slider(value: v, onChanged: handler.setUserVolume)),
    ]);
  }
}

/// Podcast playback speed for the player bars: tap for the next speed,
/// long-press to pick one. Hidden unless a podcast is playing.
class PodcastSpeedButton extends ConsumerWidget {
  const PodcastSpeedButton({super.key, this.color});
  final Color? color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    if (track?.source != TrackSource.podcast) return const SizedBox.shrink();
    final speed = ref.watch(settingsProvider.select((s) => s.podcastSpeed));
    final notifier = ref.read(settingsProvider.notifier);
    final next = podcastSpeeds[(podcastSpeeds.indexOf(speed) + 1) % podcastSpeeds.length];
    return Tooltip(
      message: '播放速度（點一下切換，長按選擇）',
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => notifier.setPodcastSpeed(next),
        onLongPress: () => showModalBottomSheet(
          context: context,
          useRootNavigator: true,
          showDragHandle: true,
          builder: (ctx) => SafeArea(
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const ListTile(title: Text('播放速度', style: TextStyle(fontWeight: FontWeight.bold))),
                for (final v in podcastSpeeds)
                  ListTile(
                    title: Text('${v}x'),
                    trailing: v == speed ? const Icon(Icons.check, color: AppColors.accent) : null,
                    onTap: () {
                      Navigator.pop(ctx);
                      notifier.setPodcastSpeed(v);
                    },
                  ),
              ]),
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Text('${speed}x', style: TextStyle(fontWeight: FontWeight.bold, color: color)),
        ),
      ),
    );
  }
}
