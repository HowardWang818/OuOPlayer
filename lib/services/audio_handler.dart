import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

import '../data/db/database.dart';
import '../data/models/track.dart';
import 'car_browser.dart';

/// Bridges just_audio to audio_service so playback shows up in the Android
/// notification / lock screen, Bluetooth AVRCP and Windows SMTC.
class OuoAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  OuoAudioHandler(this._db) {
    _init();
  }

  final AppDatabase _db;
  /// Android's system equalizer on the player's audio session (null on
  /// Windows, where mpv filters are used instead).
  final AndroidEqualizer? equalizer = Platform.isAndroid ? AndroidEqualizer() : null;
  late final player = AudioPlayer(
    audioPipeline: equalizer == null ? null : AudioPipeline(androidAudioEffects: [equalizer!]),
  );
  List<Track> _tracks = [];
  Timer? _saveTimer;
  Track? _currentListenedTrack;
  bool _loadingQueue = false;

  // Shuffle reorders the real queue (current song first, the rest random),
  // so the queue page, next and previous all follow what is actually played.
  // [_unshuffled] keeps the original order to restore when shuffle is turned off.
  bool _shuffled = false;
  List<Track> _unshuffled = [];
  final _shuffleChanges = StreamController<bool>.broadcast();
  final _random = Random();

  bool get shuffled => _shuffled;
  Stream<bool> get shuffleStream async* {
    yield _shuffled;
    yield* _shuffleChanges.stream;
  }

  // Playback settings, kept in sync by playbackSettingsProvider.
  double podcastSpeed = 1.0;
  bool podcastSkipSilence = false;
  bool continueAfterQueue = true;
  int seekSeconds = 15;

  /// 播放／暫停淡入淡出 length (0 = off). Track changes never fade.
  int fadeMs = 500;
  int _fadeRun = 0;

  /// Ramps the volume to [target]; a newer ramp (or [_stopFade]) cancels it.
  Future<void> _fadeTo(double target) async {
    final run = ++_fadeRun;
    const step = Duration(milliseconds: 25);
    final steps = max(1, fadeMs ~/ step.inMilliseconds);
    final from = player.volume;
    for (var i = 1; i <= steps; i++) {
      await Future.delayed(step);
      if (run != _fadeRun) return;
      await player.setVolume(fadeVolume(from, target, i / steps));
    }
  }

  /// Ends any ramp and puts the volume back to full.
  Future<void> _stopFade() async {
    _fadeRun++;
    if (player.volume != 1) await player.setVolume(1);
  }

  List<Track> get tracks => List.unmodifiable(_tracks);
  /// Podcast resume points: saved every few seconds while an episode plays,
  /// on pause and when the episode changes.
  Timer? _podcastTimer;
  Track? _podcastTrack;

  /// The episode's own position and length, kept while it is the current
  /// track. When the next track starts the player already reports that
  /// track's position (0), so saving must not read the player then.
  Duration _podcastPos = Duration.zero;
  Duration? _podcastDur;

  /// Follows the player only while [_podcastTrack] is really playing.
  void _trackPodcastPosition(Duration pos) {
    final t = _podcastTrack;
    if (t == null || !identical(currentTrack, t) || _loadingQueue) return;
    _podcastPos = pos;
    _podcastDur = player.duration ?? _podcastDur;
  }

  /// Within this much of the end an episode counts as finished.
  static const podcastFinishedMargin = Duration(seconds: 30);

  Future<void> _savePodcast({bool? finished, bool notify = true}) async {
    final t = _podcastTrack;
    if (t == null) return;
    final pos = _podcastPos;
    final dur = _podcastDur ?? t.duration;
    final done = finished ?? (dur != null && dur > Duration.zero && pos >= dur - podcastFinishedMargin);
    await _db.savePodcastProgress(t.uri, done ? Duration.zero : pos, dur, finished: done, notify: notify);
  }

  /// Leaving an episode saves where it was; starting one jumps back there.
  Future<void> _onPodcastTrack(Track t, int index) async {
    if (_podcastTrack != null && !identical(_podcastTrack, t)) await _savePodcast();
    _podcastTimer?.cancel();
    _podcastTrack = null;
    if (t.source != TrackSource.podcast) return;
    _podcastTrack = t;
    _podcastPos = Duration.zero;
    _podcastDur = t.duration;
    final saved = (await _db.podcastProgress())[t.uri];
    if (saved != null && !saved.finished && saved.position > const Duration(seconds: 10) && player.currentIndex == index) {
      _podcastPos = saved.position;
      _podcastDur = saved.duration ?? _podcastDur;
      await player.seek(saved.position, index: index);
    }
    _podcastTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (player.playing) _savePodcast(notify: false);
    });
  }

  Track? get currentTrack {
    final i = player.currentIndex;
    return i == null || i >= _tracks.length ? null : _tracks[i];
  }

  Future<void> _init() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    // Headphones unplugged / Bluetooth disconnected → pause.
    // No fade here: the sound must stop before it comes out of the speaker.
    session.becomingNoisyEventStream.listen((_) => pause(fade: false));
    session.interruptionEventStream.listen((e) {
      if (e.begin && e.type != AudioInterruptionType.duck) pause(fade: false);
    });

    player.playbackEventStream.listen(_broadcastState, onError: (Object e, StackTrace st) {});
    player.playingStream.listen((_) => _broadcastState(player.playbackEvent));
    _shuffleChanges.stream.listen((_) => _broadcastState(player.playbackEvent));
    player.loopModeStream.listen((_) => _broadcastState(player.playbackEvent));
    // currentIndexStream re-emits on every playback event, not only when the
    // track changes; reacting to each one (setSpeed emits another event) looped.
    player.currentIndexStream.listen((i) {
      // While a new queue loads, the index can still point into the old one.
      if (!_loadingQueue) _onTrackIndex(i);
    });
    player.durationStream.listen((d) {
      // The new track's duration can arrive before its index change; only
      // update the item it belongs to, or a stale item reaches the system
      // (audio_service sends updates on separate threads, so order can flip).
      final item = mediaItem.value;
      final t = currentTrack;
      if (item == null || d == null || t == null || item.id != t.uri || item.duration == d) return;
      mediaItem.add(item.copyWith(duration: d));
    });
    player.processingStateStream.listen((s) {
      if (s == ProcessingState.completed) {
        if (_podcastTrack != null) _savePodcast(finished: true);
        _onQueueEnd();
      }
    });
    player.playingStream.listen((playing) {
      if (!playing && _podcastTrack != null) _savePodcast();
      _onPlayingForLog(playing);
    });
    player.positionStream.listen(_trackPodcastPosition);
    _db.changes.listen((_) => _refreshLiked());
  }

  /// Called when the current index may have changed; acts only on a real track change.
  void _onTrackIndex(int? i, {bool record = true}) {
    if (i == null || i >= _tracks.length) return;
    final t = _tracks[i];
    if (identical(t, _currentListenedTrack)) return;
    // Only act when the player really holds this track at [i].
    final sequence = player.sequence;
    final tag = i < sequence.length ? sequence[i].tag : null;
    if (tag is! MediaItem || tag.id != t.uri) return;
    _currentListenedTrack = t;
    final item = t.toMediaItem();
    // Keep a duration that may already have arrived for this track.
    mediaItem.add(item.duration == null && player.duration != null ? item.copyWith(duration: player.duration) : item);
    _applyTrackSettings(t);
    _applyPreviewLoop();
    _onPodcastTrack(t, i);
    _refreshLiked();
    if (record && t.source != TrackSource.preview) {
      _db.addHistory(t);
      _startLog(t);
    }
    _scheduleSave();
  }

  /// Runs [load] with index events muted, then handles the resulting track once.
  Future<void> _loadQueue(Future<void> Function() load, {bool record = true}) async {
    _loadingQueue = true;
    try {
      await load();
    } finally {
      _loadingQueue = false;
    }
    _onTrackIndex(player.currentIndex, record: record);
  }

  void updatePlaybackSettings({
    required double podcastSpeed,
    required bool podcastSkipSilence,
    required bool continueAfterQueue,
    required int seekSeconds,
    int fadeMs = 500,
  }) {
    this.fadeMs = fadeMs;
    this.podcastSpeed = podcastSpeed;
    this.podcastSkipSilence = podcastSkipSilence;
    this.continueAfterQueue = continueAfterQueue;
    this.seekSeconds = seekSeconds;
    _applyTrackSettings(currentTrack);
  }

  /// Speed and skip-silence only apply to podcasts; music always plays as is.
  Future<void> _applyTrackSettings(Track? t) async {
    final podcast = t?.source == TrackSource.podcast;
    final speed = podcast ? podcastSpeed : 1.0;
    final skip = podcast && podcastSkipSilence;
    try {
      if (player.speed != speed) await player.setSpeed(speed);
      if (Platform.isAndroid && player.skipSilenceEnabled != skip) await player.setSkipSilenceEnabled(skip);
    } catch (_) {}
  }

  /// Only 30-second previews are queued: they play once and stop.
  bool get _previewOnly => _tracks.isNotEmpty && _tracks.every((t) => t.source == TrackSource.preview);

  /// The repeat mode chosen by the user while previews keep the player's own
  /// loop mode off; restored when real songs are queued again.
  LoopMode? _loopBeforePreview;

  Future<void> _applyPreviewLoop() async {
    if (_previewOnly) {
      if (_loopBeforePreview == null && player.loopMode != LoopMode.off) {
        _loopBeforePreview = player.loopMode;
        await player.setLoopMode(LoopMode.off);
      }
    } else if (_loopBeforePreview != null) {
      final mode = _loopBeforePreview!;
      _loopBeforePreview = null;
      await player.setLoopMode(mode);
    }
  }

  /// End of the queue: keep going with random library songs, or stop.
  /// A finished preview always stops.
  Future<void> _onQueueEnd() async {
    if (continueAfterQueue && !_previewOnly) {
      final more = await _db.randomTracks(20, exclude: _tracks.map((t) => t.id).toSet());
      if (more.isNotEmpty) {
        await playTracks(more);
        return;
      }
    }
    await player.pause();
    await player.seek(Duration.zero, index: 0);
  }

  Future<void> seekBy(int seconds) async {
    var target = player.position + Duration(seconds: seconds);
    final d = player.duration;
    if (target < Duration.zero) target = Duration.zero;
    if (d != null && target > d) target = d;
    await player.seek(target);
  }

  // ---- Listening log: how long each play was really heard ----
  int? _logId;
  Duration _heard = Duration.zero;
  DateTime? _playingSince;
  Timer? _logTimer;

  Duration get _heardNow =>
      _heard + (_playingSince == null ? Duration.zero : DateTime.now().difference(_playingSince!));

  /// Playback started or stopped: count only time actually playing.
  void _onPlayingForLog(bool playing) {
    if (playing) {
      // A restored session isn't logged until it really plays.
      final t = currentTrack;
      if (_logId == null && !_logStarting && t != null && t.source != TrackSource.preview) {
        _startLog(t);
        return;
      }
      _playingSince ??= DateTime.now();
    } else if (_playingSince != null) {
      _heard = _heardNow;
      _playingSince = null;
      _flushLog();
    }
  }

  void _flushLog() {
    final id = _logId;
    if (id != null) _db.updateListening(id, _heardNow).catchError((_) {});
  }

  /// A new song: close the previous entry and open one (previews aren't logged).
  bool _logStarting = false;

  Future<void> _startLog(Track t) async {
    _flushLog();
    _logTimer?.cancel();
    _logId = null;
    _heard = Duration.zero;
    _playingSince = player.playing ? DateTime.now() : null;
    if (t.source == TrackSource.preview) return;
    _logStarting = true;
    try {
      _logId = await _db.startListening(t, DateTime.now());
    } finally {
      _logStarting = false;
    }
    // Also saved now and then, in case the app is closed while playing.
    _logTimer = Timer.periodic(const Duration(seconds: 30), (_) => _flushLog());
  }

  // ---- Android Auto / media browsers ----
  /// Set in main once the providers exist (podcast episodes need them).
  CarBrowser? carBrowser;

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    try {
      return await carBrowser?.children(parentMediaId) ?? const [];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    final found = await carBrowser?.resolve(mediaId);
    if (found != null) await playTracks(found.$1, index: found.$2);
  }

  @override
  Future<List<MediaItem>> search(String query, [Map<String, dynamic>? extras]) async =>
      await carBrowser?.search(query) ?? const [];

  /// 「用 OuOPlayer 播放 …」: the matching songs; nothing said → liked songs,
  /// or the whole library shuffled.
  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) async {
    final q = query.trim();
    if (q.isNotEmpty) {
      final found = await _db.search(q);
      if (found.isNotEmpty) return playTracks(found);
    }
    final liked = await _db.favorites();
    if (liked.isNotEmpty) return playTracks(liked, shuffle: true);
    final all = await _db.tracks();
    if (all.isNotEmpty) await playTracks(all, shuffle: true);
  }

  /// ♥ in the notification and on the lock screen.
  static const favoriteAction = 'toggle_favorite';
  bool _currentLiked = false;

  /// Re-reads whether the current song is liked (track change, or a like
  /// changed anywhere in the app) and redraws the notification if needed.
  Future<void> _refreshLiked() async {
    final t = currentTrack;
    final liked = t != null && (await _db.favoriteIds()).contains(t.id);
    if (liked == _currentLiked) return;
    _currentLiked = liked;
    _broadcastState(player.playbackEvent);
  }

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name != favoriteAction) return super.customAction(name, extras);
    final t = currentTrack;
    if (t == null) return null;
    await _db.setFavorite(t, !_currentLiked);
    await _refreshLiked();
    return null;
  }

  void _broadcastState(PlaybackEvent event) {
    final playing = player.playing;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        // Expanded notification only (compact view keeps the first three).
        if (currentTrack != null)
          MediaControl.custom(
            androidIcon: _currentLiked ? 'drawable/ic_action_favorite' : 'drawable/ic_action_favorite_border',
            label: _currentLiked ? '從已按讚的歌曲移除' : '加到已按讚的歌曲',
            name: favoriteAction,
          ),
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
      shuffleMode: _shuffled ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
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

  /// Replace the queue and start playing at [index]. [shuffle] turns shuffle
  /// on and starts from a random song; if shuffle is already on, the chosen
  /// song plays first and the rest are shuffled (like Spotify).
  Future<void> playTracks(List<Track> list, {int index = 0, bool shuffle = false}) async {
    final playable = list.where((t) => t.fileExists).toList();
    if (playable.isEmpty) return;
    final start = list[index.clamp(0, list.length - 1)];
    var startIndex = playable.indexOf(start);
    if (startIndex < 0) startIndex = 0;
    if (shuffle) startIndex = _random.nextInt(playable.length);
    final shuffleOn = shuffle || _shuffled;
    final order = shuffleOn ? shuffledQueue(playable, startIndex, _random) : playable;
    await _loadQueue(() async {
      _tracks = order;
      _unshuffled = shuffleOn ? playable : [];
      _setShuffled(shuffleOn);
      queue.add(_tracks.map((t) => t.toMediaItem()).toList());
      try {
        await player.setShuffleModeEnabled(false);
        await player.setAudioSources(_tracks.map(_source).toList(),
            initialIndex: shuffleOn ? 0 : startIndex, initialPosition: Duration.zero);
      } catch (_) {}
    });
    await _applyPreviewLoop();
    await _stopFade();
    player.play();
    _scheduleSave();
  }

  Future<void> playNext(Track t) async {
    if (_tracks.isEmpty) return playTracks([t]);
    final at = (player.currentIndex ?? -1) + 1;
    if (_shuffled) {
      final cur = currentTrack;
      final i = cur == null ? -1 : _unshuffled.indexWhere((x) => identical(x, cur));
      _unshuffled.insert(i + 1, t);
    }
    _tracks.insert(at, t);
    await player.insertAudioSource(at, _source(t));
    queue.add(_tracks.map((t) => t.toMediaItem()).toList());
    _scheduleSave();
  }

  Future<void> enqueue(List<Track> list) async {
    if (_tracks.isEmpty) return playTracks(list);
    _tracks.addAll(list);
    if (_shuffled) _unshuffled.addAll(list);
    await player.addAudioSources(list.map(_source).toList());
    queue.add(_tracks.map((t) => t.toMediaItem()).toList());
    _scheduleSave();
  }

  Future<void> removeAt(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final removed = _tracks.removeAt(index);
    _unshuffled.removeWhere((x) => identical(x, removed));
    await player.removeAudioSourceAt(index);
    queue.add(_tracks.map((t) => t.toMediaItem()).toList());
    _scheduleSave();
  }

  /// Drops every queue entry for [trackId] (e.g. its file was deleted),
  /// moving on to the next song first if it is the one playing.
  /// Shows edited song details in the queue and the notification.
  void updateTrackInfo(Track t) {
    var changed = false;
    for (var i = 0; i < _tracks.length; i++) {
      if (_tracks[i].id == t.id) {
        _tracks[i] = t;
        changed = true;
      }
    }
    if (!changed) return;
    queue.add(_tracks.map((x) => x.toMediaItem()).toList());
    if (currentTrack?.id == t.id) {
      final item = t.toMediaItem();
      mediaItem.add(player.duration == null ? item : item.copyWith(duration: player.duration));
    }
    _scheduleSave();
  }

  Future<void> removeTrack(String trackId) async {
    if (currentTrack?.id == trackId) {
      final others = _tracks.any((t) => t.id != trackId);
      if (others && player.hasNext) {
        await player.seekToNext();
      } else {
        await player.stop();
      }
    }
    for (var i = _tracks.length - 1; i >= 0; i--) {
      if (_tracks[i].id == trackId) await removeAt(i);
    }
    if (_tracks.isEmpty) mediaItem.add(null);
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
    // A queue of previews isn't worth resuming (e.g. on Bluetooth reconnect).
    if (_tracks.isEmpty || _tracks.every((t) => t.source == TrackSource.preview)) return;
    final data = {
      'tracks': _tracks.map((t) => t.toMap()).toList(),
      'index': player.currentIndex ?? 0,
      'position': player.position.inMilliseconds,
      // Pre-shuffle order, as indexes into the saved queue.
      if (_shuffled) 'original': _unshuffled.map((t) => _tracks.indexWhere((x) => identical(x, t))).toList(),
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
      final index = (data['index'] as int).clamp(0, list.length - 1);
      // Restoring isn't listening yet, so it doesn't go into the history.
      await _loadQueue(record: false, () async {
        _tracks = list;
        queue.add(_tracks.map((t) => t.toMediaItem()).toList());
        final original = (data['original'] as List?)?.cast<int>();
        final valid = original != null && original.length == list.length && original.every((i) => i >= 0 && i < list.length);
        _unshuffled = valid ? [for (final i in original) list[i]] : [];
        _setShuffled(valid);
        await player.setShuffleModeEnabled(false);
        await player.setAudioSources(list.map(_source).toList(),
            initialIndex: index, initialPosition: Duration(milliseconds: data['position'] as int? ?? 0));
      });
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
    if (fadeMs > 0 && !player.playing) {
      await player.setVolume(0);
      unawaited(_fadeTo(1));
    } else {
      await _stopFade();
    }
    await player.play();
  }

  /// Fades out first (unless [fade] is false, e.g. headphones unplugged).
  @override
  Future<void> pause({bool fade = true}) async {
    if (fade && fadeMs > 0 && player.playing) {
      await _fadeTo(0);
      // Cancelled by a play() during the fade: keep playing.
      if (player.volume > 0) return;
    }
    await player.pause();
    await _stopFade();
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
  Future<void> fastForward() => seekBy(seekSeconds);

  @override
  Future<void> rewind() => seekBy(-seekSeconds);

  @override
  Future<void> skipToPrevious() async {
    // Past 3 seconds, restart the song (like Spotify); otherwise go back one
    // song in the queue, or restart if this is the first one.
    if (player.position > const Duration(seconds: 3) || !player.hasPrevious) {
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
    if (on == _shuffled) return;
    final cur = player.currentIndex;
    if (_tracks.isEmpty || cur == null || cur >= _tracks.length) {
      _setShuffled(on);
      return;
    }
    if (on) {
      _unshuffled = List.of(_tracks);
      await _rearrange(shuffledQueue(_tracks, cur, _random));
    } else {
      await _rearrange(unshuffledQueue(_unshuffled, _tracks));
      _unshuffled = [];
    }
    _setShuffled(on);
  }

  void _setShuffled(bool on) {
    if (_shuffled == on) return;
    _shuffled = on;
    _shuffleChanges.add(on);
  }

  /// Puts the queue into [order] without interrupting the song that is
  /// playing: everything around it is removed and re-inserted.
  Future<void> _rearrange(List<Track> order) async {
    final cur = player.currentIndex!;
    final current = _tracks[cur];
    final at = order.indexWhere((t) => identical(t, current));
    _loadingQueue = true;
    try {
      if (cur + 1 < _tracks.length) await player.removeAudioSourceRange(cur + 1, _tracks.length);
      if (cur > 0) await player.removeAudioSourceRange(0, cur);
      if (at > 0) await player.insertAudioSources(0, order.sublist(0, at).map(_source).toList());
      if (at + 1 < order.length) await player.addAudioSources(order.sublist(at + 1).map(_source).toList());
      _tracks = order;
    } finally {
      _loadingQueue = false;
    }
    queue.add(_tracks.map((t) => t.toMediaItem()).toList());
    _scheduleSave();
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) => _setLoop(const {
        AudioServiceRepeatMode.none: LoopMode.off,
        AudioServiceRepeatMode.one: LoopMode.one,
        AudioServiceRepeatMode.all: LoopMode.all,
        AudioServiceRepeatMode.group: LoopMode.all,
      }[repeatMode]!);

  /// While previews play, a new repeat mode is kept for later instead.
  Future<void> _setLoop(LoopMode mode) async {
    if (_previewOnly) {
      _loopBeforePreview = mode == LoopMode.off ? null : mode;
      return;
    }
    _loopBeforePreview = null;
    await player.setLoopMode(mode);
  }

  Future<void> toggleShuffle() => setShuffleMode(_shuffled ? AudioServiceShuffleMode.none : AudioServiceShuffleMode.all);

  Future<void> cycleRepeat() => _setLoop(const {
        LoopMode.off: LoopMode.all,
        LoopMode.all: LoopMode.one,
        LoopMode.one: LoopMode.off,
      }[_loopBeforePreview ?? player.loopMode]!);

  @override
  Future<void> onTaskRemoved() => stop();
}

/// Shuffled copy of [list] with the item at [current] moved to the front.
List<T> shuffledQueue<T>(List<T> list, int current, Random random) {
  final rest = [for (var i = 0; i < list.length; i++) if (i != current) list[i]]..shuffle(random);
  return [list[current], ...rest];
}

/// The pre-shuffle order for what is in [queue] now: items still queued keep
/// their [original] order; items added while shuffled go at the end.
List<T> unshuffledQueue<T>(List<T> original, List<T> queue) {
  final kept = [for (final t in original) if (queue.any((q) => identical(q, t))) t];
  final added = [for (final q in queue) if (!kept.any((t) => identical(t, q))) q];
  return [...kept, ...added];
}

/// Volume part way ([t] from 0 to 1) through a fade; eased so it sounds even.
double fadeVolume(double from, double to, double t) {
  final eased = t * t * (3 - 2 * t);
  return (from + (to - from) * eased).clamp(0.0, 1.0);
}
