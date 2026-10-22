import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

import '../data/db/database.dart';
import '../data/models/track.dart';

/// Bridges just_audio to audio_service so playback shows up in the Android
/// notification / lock screen, Bluetooth AVRCP and Windows SMTC.
class OuoAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  OuoAudioHandler(this._db) {
    _init();
  }

  final AppDatabase _db;
  final player = AudioPlayer();
  List<Track> _tracks = [];
  Timer? _saveTimer;

  List<Track> get tracks => List.unmodifiable(_tracks);
  Track? get currentTrack {
    final i = player.currentIndex;
    return i == null || i >= _tracks.length ? null : _tracks[i];
  }

  Future<void> _init() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    // Headphones unplugged / Bluetooth disconnected → pause.
    session.becomingNoisyEventStream.listen((_) => pause());
    session.interruptionEventStream.listen((e) {
      if (e.begin && e.type != AudioInterruptionType.duck) pause();
    });

    player.playbackEventStream.listen(_broadcastState, onError: (Object e, StackTrace st) {});
    player.playingStream.listen((_) => _broadcastState(player.playbackEvent));
    player.shuffleModeEnabledStream.listen((_) => _broadcastState(player.playbackEvent));
    player.loopModeStream.listen((_) => _broadcastState(player.playbackEvent));
    player.currentIndexStream.listen((i) {
      if (i == null || i >= _tracks.length) return;
      final t = _tracks[i];
      mediaItem.add(t.toMediaItem());
      _db.addHistory(t);
      _scheduleSave();
    });
    player.durationStream.listen((d) {
      final item = mediaItem.value;
      if (item != null && d != null && item.duration != d) mediaItem.add(item.copyWith(duration: d));
    });
    player.processingStateStream.listen((s) {
      if (s == ProcessingState.completed) {
        player.pause();
        player.seek(Duration.zero, index: 0);
      }
    });
  }

  void _broadcastState(PlaybackEvent event) {
    final playing = player.playing;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[player.processingState]!,
      playing: playing,
      updatePosition: player.position,
      bufferedPosition: player.bufferedPosition,
      speed: player.speed,
      queueIndex: event.currentIndex,
      shuffleMode: player.shuffleModeEnabled ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
      repeatMode: const {
        LoopMode.off: AudioServiceRepeatMode.none,
        LoopMode.one: AudioServiceRepeatMode.one,
        LoopMode.all: AudioServiceRepeatMode.all,
      }[player.loopMode]!,
    ));
  }

  AudioSource _source(Track t) {
    final uri = t.isRemote ? Uri.parse(t.uri) : Uri.file(t.uri);
    return AudioSource.uri(uri, tag: t.toMediaItem());
  }

  /// Replace the queue and start playing at [index].
  Future<void> playTracks(List<Track> list, {int index = 0, bool shuffle = false}) async {
    final playable = list.where((t) => t.fileExists).toList();
    if (playable.isEmpty) return;
    final start = list[index.clamp(0, list.length - 1)];
    var startIndex = playable.indexOf(start);
    if (startIndex < 0) startIndex = 0;
    _tracks = playable;
    queue.add(_tracks.map((t) => t.toMediaItem()).toList());
    await player.setShuffleModeEnabled(shuffle);
    try {
      await player.setAudioSources(_tracks.map(_source).toList(), initialIndex: startIndex, initialPosition: Duration.zero);
      if (shuffle) await player.shuffle();
      if (shuffle && player.effectiveIndices.isNotEmpty) {
        await player.seek(Duration.zero, index: player.effectiveIndices.first);
      }
    } catch (_) {}
    player.play();
    _scheduleSave();
  }

  Future<void> playNext(Track t) async {
    if (_tracks.isEmpty) return playTracks([t]);
    final at = (player.currentIndex ?? -1) + 1;
    _tracks.insert(at, t);
    await player.insertAudioSource(at, _source(t));
    queue.add(_tracks.map((t) => t.toMediaItem()).toList());
    _scheduleSave();
  }

  Future<void> enqueue(List<Track> list) async {
    if (_tracks.isEmpty) return playTracks(list);
    _tracks.addAll(list);
    await player.addAudioSources(list.map(_source).toList());
    queue.add(_tracks.map((t) => t.toMediaItem()).toList());
    _scheduleSave();
  }

  Future<void> removeAt(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    _tracks.removeAt(index);
    await player.removeAudioSourceAt(index);
    queue.add(_tracks.map((t) => t.toMediaItem()).toList());
    _scheduleSave();
  }

  Future<void> moveQueueItem(int from, int to) async {
    final t = _tracks.removeAt(from);
    _tracks.insert(to, t);
    await player.moveAudioSource(from, to);
    queue.add(_tracks.map((t) => t.toMediaItem()).toList());
    _scheduleSave();
  }

  // ---------- persistence: resume the last queue (used by Bluetooth auto-play) ----------
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), saveSession);
  }

  Future<void> saveSession() async {
    final data = {
      'tracks': _tracks.map((t) => t.toMap()).toList(),
      'index': player.currentIndex ?? 0,
      'position': player.position.inMilliseconds,
    };
    await _db.setSetting('last_session', jsonEncode(data));
  }

  Future<bool> restoreSession({bool autoPlay = false}) async {
    if (_tracks.isNotEmpty) return true;
    final raw = (await _db.allSettings())['last_session'];
    if (raw == null || raw.isEmpty) return false;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final list = (data['tracks'] as List).map((m) => Track.fromMap((m as Map).cast<String, Object?>())).where((t) => t.fileExists).toList();
      if (list.isEmpty) return false;
      _tracks = list;
      queue.add(_tracks.map((t) => t.toMediaItem()).toList());
      final index = (data['index'] as int).clamp(0, list.length - 1);
      await player.setAudioSources(list.map(_source).toList(),
          initialIndex: index, initialPosition: Duration(milliseconds: data['position'] as int? ?? 0));
      if (autoPlay) player.play();
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---------- audio_service overrides ----------
  @override
  Future<void> play() async {
    if (_tracks.isEmpty) {
      if (!await restoreSession()) return;
    }
    await player.play();
  }

  @override
  Future<void> pause() async {
    await player.pause();
    await saveSession();
  }

  @override
  Future<void> stop() async {
    await saveSession();
    await player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> skipToNext() => player.seekToNext();

  @override
  Future<void> skipToPrevious() async {
    if (player.position > const Duration(seconds: 3)) {
      await player.seek(Duration.zero);
    } else {
      await player.seekToPrevious();
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    await player.seek(Duration.zero, index: index);
    player.play();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final on = shuffleMode != AudioServiceShuffleMode.none;
    if (on) await player.shuffle();
    await player.setShuffleModeEnabled(on);
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) => player.setLoopMode(const {
        AudioServiceRepeatMode.none: LoopMode.off,
        AudioServiceRepeatMode.one: LoopMode.one,
        AudioServiceRepeatMode.all: LoopMode.all,
        AudioServiceRepeatMode.group: LoopMode.all,
      }[repeatMode]!);

  Future<void> toggleShuffle() =>
      setShuffleMode(player.shuffleModeEnabled ? AudioServiceShuffleMode.none : AudioServiceShuffleMode.all);

  Future<void> cycleRepeat() => player.setLoopMode(const {
        LoopMode.off: LoopMode.all,
        LoopMode.all: LoopMode.one,
        LoopMode.one: LoopMode.off,
      }[player.loopMode]!);

  @override
  Future<void> onTaskRemoved() => stop();
}
