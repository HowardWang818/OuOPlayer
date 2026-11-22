import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart' show BehaviorSubject, ValueStream;

import '../data/db/database.dart';
import '../data/models/track.dart';
import 'car_browser.dart';
import 'preview_return.dart';

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

  // 加入佇列 (like Spotify): songs queued by hand play right after the current
  // one, in the order added, before the rest; shuffling leaves them in place.
  final Set<Track> _upNext = Set.identity();

  /// Queued by hand and not played yet (see [enqueue]).
  bool isQueuedAt(int index) => index >= 0 && index < _tracks.length && _upNext.contains(_tracks[index]);

  /// Which list the queue was started from ([playTracks]' `source`), e.g.
  /// 'playlist:3'; a list's shuffle button is lit only for its own queue.
  String? queueSource;
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

  /// 試聽完回到原本的佇列: the queue set aside while a preview plays.
  BeforePreview? _before;

  /// That queue while it is being loaded again.
  BeforePreview? _returning;

  /// Goes up whenever the queue is replaced: what was loading gives way.
  int _queueRun = 0;

  /// The preview loaded: an error from here on is one part way through.
  /// (While it loads, Android reports one both ways, in either order.)
  bool _previewLoaded = false;

  bool get _previewing => _before != null || _returning != null || _previewOnly;

  /// Another queue takes the player's place: no going back any more.
  void _replaced() {
    _queueRun++;
    _before = null;
    _returning = null;
  }

  /// 記錄播放紀錄: off → no recently played, play counts or listening log
  /// (podcast resume points are still kept).
  bool recordPlays = true;

  /// 隨機播放時，沒播過的歌優先.
  bool unplayedFirst = true;

  /// 播放／暫停淡入淡出 length (0 = off). Track changes never fade.
  int fadeMs = 500;
  int _fadeRun = 0;

  /// The volume the user chose (the slider on Windows). Fades only scale
  /// it, so play / pause never move the slider or undo a mute.
  final userVolume = BehaviorSubject<double>.seeded(1);

  /// 0–1 during a play / pause fade, 1 otherwise.
  double _fadeGain = 1;

  Future<void> _applyVolume() => player.setVolume((userVolume.value * _fadeGain).clamp(0.0, 1.0));

  double _beforeMute = 1;

  /// Mutes, or goes back to the volume before muting.
  Future<void> toggleMute() async {
    final v = userVolume.value;
    if (v > 0) _beforeMute = v;
    await setUserVolume(v > 0 ? 0 : _beforeMute);
  }

  Future<void> setUserVolume(double v) async {
    userVolume.add(v.clamp(0.0, 1.0));
    await _applyVolume();
    unawaited(_db.setSetting('user_volume', '${userVolume.value}'));
  }

  /// Ramps the fade gain to [target]; a newer ramp (or [_stopFade]) cancels it.
  Future<void> _fadeTo(double target) async {
    final run = ++_fadeRun;
    const step = Duration(milliseconds: 25);
    final steps = max(1, fadeMs ~/ step.inMilliseconds);
    final from = _fadeGain;
    for (var i = 1; i <= steps; i++) {
      await Future.delayed(step);
      if (run != _fadeRun) return;
      _fadeGain = fadeVolume(from, target, i / steps);
      await _applyVolume();
    }
  }

  /// Ends any ramp: back to the user's volume.
  Future<void> _stopFade() async {
    _fadeRun++;
    _fadeGain = 1;
    await _applyVolume();
  }

  /// Everything queued, the queue set aside for a preview included.
  List<Track> get tracks => List.unmodifiable([..._tracks, ...?_before?.tracks]);
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

  /// The song after the current one (null at the end of the queue).
  /// Called just before the song changes, so 音量平衡 is ready for it (a gain
  /// sent after the change misses the start, which mpv has already decoded).
  Future<void> Function(Track next)? beforeSwitch;

  Future<void> _ready(Track? next) async {
    if (next == null) return;
    try {
      await beforeSwitch?.call(next).timeout(const Duration(milliseconds: 300));
    } catch (_) {}
  }

  Track? get nextTrack {
    final i = player.currentIndex;
    return i == null || i + 1 >= _tracks.length ? null : _tracks[i + 1];
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
    // Pressing play or pause counts at once: even a few seconds' play is the
    // last play (接續播放 compares devices by it).
    var wasPlaying = false;
    player.playingStream.listen((on) {
      if (on == wasPlaying) return;
      wasPlaying = on;
      // A preview is not a play: 接續播放 doesn't go by it.
      if (_previewing) return;
      lastPlayedAt = DateTime.now();
      _scheduleSave();
    });
    var ticks = 0;
    Timer.periodic(const Duration(seconds: 2), (_) {
      _checkStalled();
      if (player.playing && ++ticks % 5 == 0) unawaited(saveSession());
    });
    // The volume chosen last time.
    _db.allSettings().then((m) {
      final v = double.tryParse(m['user_volume'] ?? '');
      if (v != null) setUserVolume(v);
    });
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
    // A preview that breaks off part way goes back too.
    player.errorStream.listen((_) {
      if (_before != null && _previewLoaded) unawaited(_endPreview());
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
    _db.changes.listen((_) {
      _refreshLiked();
      // Playlists, likes and new songs show up in the car too (batched).
      _carRefresh?.cancel();
      _carRefresh = Timer(const Duration(seconds: 2), _car.changed);
    });
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
    _lyricLine = null;
    // A queued song that has come up (or been skipped past) is just part of the list now.
    for (var j = 0; j <= i; j++) {
      _upNext.remove(_tracks[j]);
    }
    final item = _item(t);
    // Keep a duration that may already have arrived for this track.
    mediaItem.add(item.duration == null && player.duration != null ? item.copyWith(duration: player.duration) : item);
    _applyTrackSettings(t);
    _applyPreviewLoop();
    _onPodcastTrack(t, i);
    _refreshLiked();
    if (record && recordPlays && t.source != TrackSource.preview) {
      _db.addHistory(t);
      _startLog(t);
    } else {
      _stopLog();
    }
    _scheduleSave();
  }

  /// Runs [load] with index events muted, then handles the resulting track once.
  Future<void> _loadQueue(Future<void> Function() load, {bool record = true}) async {
    final run = ++_loadRun;
    _loadingQueue = true;
    try {
      await load();
    } finally {
      // A load that a newer one replaced leaves that one's track to it.
      if (run == _loadRun) _loadingQueue = false;
    }
    if (run == _loadRun) _onTrackIndex(player.currentIndex, record: record);
  }

  int _loadRun = 0;

  void updatePlaybackSettings({
    required double podcastSpeed,
    required bool podcastSkipSilence,
    required bool continueAfterQueue,
    required int seekSeconds,
    int fadeMs = 500,
    bool recordPlays = true,
    bool unplayedFirst = true,
  }) {
    this.fadeMs = fadeMs;
    if (!recordPlays && this.recordPlays) _stopLog();
    this.recordPlays = recordPlays;
    this.unplayedFirst = unplayedFirst;
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
  /// A finished preview gives the queue before it back, paused.
  Future<void> _onQueueEnd() async {
    if (_before != null) return _endPreview();
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

  /// When the play being logged began (its entry's played_at).
  int? _logBegan;

  /// 接續播放 (1.20.9): the other device's play of the song just picked up,
  /// carried on in the same entry instead of a new one when it plays.
  ({Track track, int began, int heard})? _continueFrom;

  /// The play being logged: when it began and how long it was heard so far
  /// (sent with 接續播放, so the other device carries on in the same play).
  ({int began, int heard})? get currentPlay {
    final began = _logBegan;
    if (_logId == null || began == null) {
      // Back here (after a preview, or picked up), not played again yet.
      final cont = _continueFrom;
      return cont != null && identical(cont.track, currentTrack) ? (began: cont.began, heard: cont.heard) : null;
    }
    return (began: began, heard: _heardNow.inMilliseconds);
  }

  Duration get _heardNow =>
      _heard + (_playingSince == null ? Duration.zero : DateTime.now().difference(_playingSince!));

  /// Playback started or stopped: count only time actually playing.
  void _onPlayingForLog(bool playing) {
    if (playing) {
      // A restored session isn't logged until it really plays.
      final t = currentTrack;
      if (recordPlays && _logId == null && !_logStarting && t != null && t.source != TrackSource.preview) {
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

  /// Closes the current entry and logs nothing until the next song.
  void _stopLog() {
    _flushLog();
    _logTimer?.cancel();
    _logId = null;
    _logBegan = null;
    _heard = Duration.zero;
    _playingSince = null;
  }

  Future<void> _startLog(Track t) async {
    _flushLog();
    _logTimer?.cancel();
    _logId = null;
    _logBegan = null;
    _heard = Duration.zero;
    _playingSince = player.playing ? DateTime.now() : null;
    final cont = _continueFrom;
    _continueFrom = null;
    if (t.source == TrackSource.preview) return;
    _logStarting = true;
    try {
      if (cont != null && identical(cont.track, t)) {
        // Picked up from the other device: the same play goes on.
        final (id, heard, isNew) = await _db.continueListening(t, cont.began, cont.heard);
        _logId = id;
        _logBegan = cont.began;
        _heard = Duration(milliseconds: heard);
        // First time this device has the play at all: it counts here once.
        if (isNew && recordPlays) unawaited(_db.addHistory(t));
      } else {
        final now = DateTime.now();
        _logBegan = now.millisecondsSinceEpoch;
        _logId = await _db.startListening(t, now);
      }
    } finally {
      _logStarting = false;
    }
    // Also saved now and then, in case the app is closed while playing.
    _logTimer = Timer.periodic(const Duration(seconds: 30), (_) => _flushLog());
  }

  // ---- Android Auto / media browsers ----
  /// Set in main once the providers exist (podcast episodes need them).
  /// Android Auto can start the app and ask for the root before that, so
  /// [getChildren] waits for it, and setting it tells the car to reload.
  CarBrowser? get carBrowser => _car.browser;
  set carBrowser(CarBrowser? b) => _car.browser = b;
  final _car = CarLibrary();
  Timer? _carRefresh;

  @override
  ValueStream<Map<String, dynamic>> subscribeToChildren(String parentMediaId) => _car.subscribe(parentMediaId);

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) {
    // The car opening the app is a connection too (also when the app itself isn't open).
    if (parentMediaId == AudioService.browsableRootId) unawaited(carConnected());
    return _car.children(parentMediaId);
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

  /// 在車上和通知列顯示歌詞: the line being sung replaces the artist in what
  /// the car, notification and lock screen show (the app itself keeps the
  /// real artist, which travels in the item's extras).
  String? _lyricLine;

  void showLyricLine(String? line) {
    final text = line == null || line.trim().isEmpty ? null : line.trim();
    if (text == _lyricLine) return;
    _lyricLine = text;
    final t = currentTrack;
    final item = mediaItem.value;
    if (t == null || item == null || item.id != t.uri) return;
    mediaItem.add(item.copyWith(artist: text == null ? t.artist : '♪ $text'));
  }

  /// ♥ in the notification and on the lock screen.
  static const favoriteAction = 'toggle_favorite';
  static const shuffleAction = 'toggle_shuffle';

  /// The song for the media session. On Android its cover goes through
  /// ArtProvider: the car can't open the app's own files (no cover on the
  /// car's media card otherwise).
  MediaItem _item(Track t) {
    final item = t.toMediaItem();
    if (!Platform.isAndroid || t.art == null || t.art!.startsWith('http')) return item;
    return item.copyWith(artUri: CarBrowser.artUri(t.art));
  }
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
    if (name == shuffleAction) {
      await setShuffleMode(_shuffled ? AudioServiceShuffleMode.none : AudioServiceShuffleMode.all);
      return null;
    }
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
        // Shuffle on / off (the car's media card has no button of its own for it).
        if (currentTrack != null)
          MediaControl.custom(
            androidIcon: _shuffled ? 'drawable/ic_action_shuffle_on' : 'drawable/ic_action_shuffle',
            label: _shuffled ? '關閉隨機播放' : '隨機播放',
            name: shuffleAction,
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
    return AudioSource.uri(uri, tag: _item(t));
  }

  /// Replace the queue and start playing at [index]. [shuffle] turns shuffle
  /// on and starts from a random song; if shuffle is already on, the chosen
  /// song plays first and the rest are shuffled (like Spotify).
  /// [inOrder] plays the list in its own order even while shuffle is on.
  Future<void> playTracks(List<Track> list, {int index = 0, bool shuffle = false, bool inOrder = false, String? source}) async {
    final playable = list.where((t) => t.fileExists).toList();
    if (playable.isEmpty) return;
    if (playable.every((t) => t.source == TrackSource.preview)) {
      await playPreview(playable.first);
      return;
    }
    final start = list[index.clamp(0, list.length - 1)];
    var startIndex = playable.indexOf(start);
    if (startIndex < 0) startIndex = 0;
    final shuffleOn = shuffle || (_shuffled && !inOrder);
    final heard = shuffleOn ? await _heardTest() : null;
    if (shuffle) startIndex = randomStart(playable, _random, heard: heard);
    var order = shuffleOn ? shuffledQueue(playable, startIndex, _random, heard: heard) : playable;
    // Songs still waiting in 加入佇列 follow the first song of the new list.
    final waiting = _before?.waiting ?? _pendingUpNext();
    final first = shuffleOn ? 0 : startIndex;
    if (waiting.isNotEmpty) order = [...order.sublist(0, first + 1), ...waiting, ...order.sublist(first + 1)];
    await _ready(order[first]);
    await _loadQueue(() async {
      _replaced();
      queueSource = source;
      _upNext
        ..clear()
        ..addAll(waiting);
      _tracks = order;
      _unshuffled = shuffleOn ? playable : [];
      _setShuffled(shuffleOn);
      queue.add(_tracks.map(_item).toList());
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

  /// 試聽: [preview] plays by itself, then the queue before it comes back
  /// where it was, paused (several previews in a row: the one before the
  /// first). False: it wouldn't load, and the queue is back. Null: something
  /// else was played meanwhile.
  Future<bool?> playPreview(Track preview) async {
    final run = ++_queueRun;
    // Still on the way back from the last preview: still the same queue.
    _before ??= _returning;
    _returning = null;
    final wasPlaying = player.playing && !_previewing;
    await _stopFade();
    await player.pause();
    if (run != _queueRun) return null;
    if (_before == null) {
      if (wasPlaying) lastPlayedAt = DateTime.now();
      await saveSession();
    }
    await _ready(preview);
    if (run != _queueRun) return null;
    _before ??= BeforePreview(
      tracks: _tracks,
      index: player.currentIndex ?? 0,
      position: player.position,
      unshuffled: _unshuffled,
      shuffled: _shuffled,
      upNext: _upNext,
      source: queueSource,
      play: currentPlay,
    );
    _stopLog();
    _continueFrom = null;
    _previewLoaded = false;
    var ok = true;
    await _loadQueue(record: false, () async {
      _tracks = [preview];
      _unshuffled = [];
      _upNext.clear();
      queueSource = null;
      queue.add([_item(preview)]);
      // Windows reports a bad address as an error, not a failed load.
      final error = Completer<bool>();
      final errors = player.errorStream.listen((_) {
        if (!error.isCompleted) error.complete(false);
      });
      try {
        await player.setShuffleModeEnabled(false);
        ok = await Future.any([
          player
              .setAudioSources([_source(preview)], initialIndex: 0, initialPosition: Duration.zero)
              .timeout(const Duration(seconds: 20))
              .then((_) => true),
          error.future,
        ]);
      } catch (_) {
        ok = false;
      } finally {
        unawaited(errors.cancel());
      }
    });
    if (run != _queueRun) return null;
    if (!ok) {
      await _endPreview();
      return false;
    }
    _previewLoaded = true;
    // Repeat off first, or the preview would never end.
    await _applyPreviewLoop();
    await _stopFade();
    if (run != _queueRun) return null;
    unawaited(player.play());
    return true;
  }

  /// The preview ended, was skipped or wouldn't play: the queue before it,
  /// at its song and second, always paused.
  Future<void> _endPreview() async {
    final b = _before;
    if (b == null || _returning != null) return;
    final run = ++_queueRun;
    _returning = b;
    try {
      await _stopFade();
      await player.pause();
      final gone = {for (final t in b.tracks) if (!t.fileExists) t.id};
      if (gone.isNotEmpty) b.remove(gone);
      await _ready(b.current);
      if (run != _queueRun) return;
      _stopLog();
      // So the song shows again, even if the preview never came up.
      _currentListenedTrack = null;
      await _loadQueue(record: false, () async {
        // From here on changes go to the queue itself.
        _before = null;
        _tracks = List.of(b.tracks);
        _unshuffled = List.of(b.unshuffled);
        _setShuffled(b.shuffled);
        _upNext
          ..clear()
          ..addAll(b.upNext);
        queueSource = b.source;
        queue.add(_tracks.map(_item).toList());
        try {
          if (_tracks.isEmpty) {
            await player.stop();
            await player.clearAudioSources();
          } else {
            await player
                .setAudioSources(_tracks.map(_source).toList(), initialIndex: b.index, initialPosition: b.position)
                .timeout(const Duration(seconds: 20));
          }
        } catch (_) {}
      });
      if (run != _queueRun) return;
      if (_tracks.isEmpty) mediaItem.add(null);
      final t = b.current, play = b.play;
      _continueFrom = t == null || play == null ? null : (track: t, began: play.began, heard: play.heard);
      await _applyPreviewLoop();
      _scheduleSave();
    } finally {
      if (identical(_returning, b)) _returning = null;
    }
  }

  /// 加入佇列: after the current song and the songs queued before (Spotify's
  /// queue), not at the end of the list.
  Future<void> enqueue(List<Track> list) async {
    final before = _before;
    if (before != null) {
      // During a preview: into the queue that comes back.
      before.enqueue([for (final t in list) if (t.fileExists) Track.fromMap(t.toMap())]);
      _scheduleSave();
      return;
    }
    if (_tracks.isEmpty) return playTracks(list);
    final cur = player.currentIndex ?? -1;
    final at = cur + 1 + _pendingUpNext().length;
    final copies = [for (final t in list) Track.fromMap(t.toMap())];
    _tracks.insertAll(at, copies);
    _upNext.addAll(copies);
    if (_shuffled) _unshuffled.addAll(copies);
    await player.insertAudioSources(at, copies.map(_source).toList());
    queue.add(_tracks.map(_item).toList());
    _scheduleSave();
  }

  /// The hand-queued songs right after the current one, in order.
  List<Track> _pendingUpNext() {
    final cur = player.currentIndex ?? -1;
    return [for (var i = cur + 1; i < _tracks.length && _upNext.contains(_tracks[i]); i++) _tracks[i]];
  }

  Future<void> removeAt(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    // The preview taken out of the queue: back at once.
    if (_before != null) return _endPreview();
    final removed = _tracks.removeAt(index);
    _unshuffled.removeWhere((x) => identical(x, removed));
    _upNext.remove(removed);
    await player.removeAudioSourceAt(index);
    queue.add(_tracks.map(_item).toList());
    _scheduleSave();
  }

  /// Drops every queue entry for [trackId] (e.g. its file was deleted),
  /// moving on to the next song first if it is the one playing.
  /// Shows edited song details in the queue and the notification.
  void updateTrackInfo(Track t) {
    if (_before?.replace((x) => x.id == t.id ? t : null) ?? false) _scheduleSave();
    final cont = _continueFrom;
    if (cont != null && cont.track.id == t.id) _continueFrom = (track: t, began: cont.began, heard: cont.heard);
    var changed = false;
    for (var i = 0; i < _tracks.length; i++) {
      if (_tracks[i].id == t.id) {
        _tracks[i] = t;
        changed = true;
      }
    }
    if (!changed) return;
    queue.add(_tracks.map(_item).toList());
    if (currentTrack?.id == t.id) {
      final item = _item(t);
      mediaItem.add(player.duration == null ? item : item.copyWith(duration: player.duration));
    }
    _scheduleSave();
  }

  /// Songs whose files moved (資料夾 →「移到資料夾」): queue entries point at
  /// the new paths. The one playing keeps its open file until it ends.
  Future<void> relocate(Map<String, Track> moved) async {
    if (moved.isEmpty) return;
    if (_before?.replace((t) => moved[t.id]) ?? false) _scheduleSave();
    final cont = _continueFrom;
    final contTo = cont == null ? null : moved[cont.track.id];
    if (contTo != null) _continueFrom = (track: contTo, began: cont!.began, heard: cont.heard);
    final cur = player.currentIndex;
    var changed = false;
    for (var i = 0; i < _tracks.length; i++) {
      final to = moved[_tracks[i].id];
      if (to == null) continue;
      final old = _tracks[i];
      _tracks[i] = to;
      for (var j = 0; j < _unshuffled.length; j++) {
        if (identical(_unshuffled[j], old)) _unshuffled[j] = to;
      }
      if (i != cur) {
        await player.removeAudioSourceAt(i);
        await player.insertAudioSource(i, _source(to));
      }
      changed = true;
    }
    if (!changed) return;
    queue.add(_tracks.map(_item).toList());
    _scheduleSave();
  }

  Future<void> removeTrack(String trackId) => removeTracks({trackId});

  /// Drops every queue entry of [ids] at once (1.20.9). Before, each song was
  /// dropped on its own: the one playing moved on to the next, which was
  /// often being deleted too, and every song passed on the way was logged as
  /// a play (41 plays of 0 s in one second when several songs went).
  /// Now only the first song that stays is moved to, once.
  Future<void> removeTracks(Set<String> ids) async {
    final before = _before;
    if (before != null && ids.isNotEmpty) {
      before.remove(ids);
      _scheduleSave();
      if (_tracks.any((t) => ids.contains(t.id))) await _endPreview();
      return;
    }
    if (ids.isEmpty || !_tracks.any((t) => ids.contains(t.id))) return;
    final cur = player.currentIndex;
    final curGoes = cur != null && cur < _tracks.length && ids.contains(_tracks[cur].id);
    _loadingQueue = true;
    try {
      if (curGoes) {
        int? next;
        for (var i = cur + 1; i < _tracks.length; i++) {
          if (!ids.contains(_tracks[i].id)) {
            next = i;
            break;
          }
        }
        if (next != null) {
          await player.seek(Duration.zero, index: next);
        } else {
          await player.stop();
        }
      }
      for (var i = _tracks.length - 1; i >= 0; i--) {
        if (ids.contains(_tracks[i].id)) await removeAt(i);
      }
    } finally {
      _loadingQueue = false;
    }
    if (_tracks.isEmpty) {
      _stopLog();
      _currentListenedTrack = null;
      mediaItem.add(null);
    } else {
      _onTrackIndex(player.currentIndex);
    }
  }

  Future<void> moveQueueItem(int from, int to) async {
    final t = _tracks.removeAt(from);
    _tracks.insert(to, t);
    await player.moveAudioSource(from, to);
    queue.add(_tracks.map(_item).toList());
    _scheduleSave();
  }

  // ---------- persistence: resume the last queue (used by Bluetooth auto-play) ----------
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), saveSession);
  }

  /// When something last played here (接續播放 compares devices by it).
  DateTime? lastPlayedAt;

  Future<void> saveSession() async {
    // During a preview, the queue it goes back to is what's saved (the app
    // closed meanwhile opens on it).
    final before = _before ?? _returning;
    final list = before?.tracks ?? _tracks;
    // A queue of previews isn't worth resuming (e.g. on Bluetooth reconnect).
    if (list.isEmpty || list.every((t) => t.source == TrackSource.preview)) return;
    if (player.playing && !_previewing) lastPlayedAt = DateTime.now();
    final data = {
      if (lastPlayedAt != null) 'at': lastPlayedAt!.millisecondsSinceEpoch,
      'tracks': list.map((t) => t.toMap()).toList(),
      'index': before?.index ?? player.currentIndex ?? 0,
      'position': (before?.position ?? player.position).inMilliseconds,
      // Pre-shuffle order, as indexes into the saved queue.
      if (before?.shuffled ?? _shuffled) 'original': before?.original ?? originalOrder,
    };
    await _db.setSetting('last_session', jsonEncode(data));
    // 連上車子時切回音樂: the last queue without podcasts, kept apart.
    if (list.every((t) => t.source != TrackSource.podcast)) await _db.setSetting('last_music_session', jsonEncode(data));
  }

  DateTime? _carMusicAt;

  /// 連上車子時切回音樂: called when Android Auto connects (or first browses
  /// the app). If a podcast is up, its place is saved and the last music
  /// queue comes back where it was; music already playing is left alone.
  Future<bool> carConnected() async {
    final now = DateTime.now();
    if (_carMusicAt != null && now.difference(_carMusicAt!) < const Duration(minutes: 5)) return false;
    _carMusicAt = now;
    if ((await _db.allSettings())['car_music'] == 'false') return false;
    final t = currentTrack;
    if (t != null && t.source != TrackSource.podcast) return false;
    final playing = player.playing;
    if (t != null) await _savePodcast();
    return _restore('last_music_session', autoPlay: playing);
  }

  /// Songs skipped because they wouldn't play (title), for a message on screen.
  final unplayable = StreamController<String>.broadcast();

  Duration? _lastPos;
  DateTime? _stillSince;

  /// A file the player opened but can't actually play (seen on Windows with
  /// some MP3s) sits at the same position while "playing": after 10 s it's
  /// skipped, so playback never stays stuck.
  void _checkStalled() {
    final pos = player.position;
    final moving = !player.playing ||
        player.processingState != ProcessingState.ready ||
        _loadingQueue ||
        currentTrack == null ||
        currentTrack!.isRemote ||
        pos != _lastPos;
    _lastPos = pos;
    if (moving) {
      _stillSince = null;
      return;
    }
    final since = _stillSince ??= DateTime.now();
    if (DateTime.now().difference(since) < const Duration(seconds: 10)) return;
    _stillSince = null;
    final t = currentTrack!;
    unplayable.add(t.title);
    if (player.hasNext) {
      unawaited(player.seekToNext());
    } else {
      unawaited(player.pause());
    }
  }

  /// The queue in play order (接續播放 sends it to the other device).
  /// Empty while it is on the way back from a preview: the player is then
  /// between the preview's second and the song's.
  List<Track> get queueTracks => _returning != null ? const [] : List.unmodifiable(_tracks);

  /// Shuffled: the queue's order before shuffling, as indexes into [queueTracks].
  List<int>? get originalOrder => _shuffled ? _unshuffled.map((t) => _tracks.indexWhere((x) => identical(x, t))).toList() : null;

  /// 接續播放: the other device's queue, at its song and second, not playing
  /// yet. Songs not on this device are left out.
  /// [began], [heardMs]: the other device's play of the song at [index]
  /// (1.20.9), carried on here in the same entry.
  Future<bool> loadResume(List<Track?> list, int index, Duration position,
      {List<int>? original, LoopMode loop = LoopMode.off, int? began, int heardMs = 0}) async {
    final start = index >= 0 && index < list.length ? list[index] : null;
    final keep = [for (final t in list) if (t != null && t.fileExists) t];
    if (keep.isEmpty) return false;
    var at = start == null ? -1 : keep.indexOf(start);
    final pos = at < 0 ? Duration.zero : position;
    if (at < 0) at = 0;
    // The pre-shuffle order, kept only when every song came along.
    final valid = original != null && keep.length == list.length && original.length == list.length && original.every((i) => i >= 0 && i < keep.length);
    await _loadQueue(record: false, () async {
      _replaced();
      _upNext.clear();
      queueSource = null;
      _tracks = keep;
      _unshuffled = valid ? [for (final i in original) keep[i]] : [];
      _setShuffled(valid);
      queue.add(_tracks.map(_item).toList());
      await player.setShuffleModeEnabled(false);
      await player.setAudioSources(_tracks.map(_source).toList(), initialIndex: at, initialPosition: pos).timeout(const Duration(seconds: 20));
    });
    await _setLoop(loop);
    if (began != null && start != null && at < keep.length && identical(keep[at], start)) {
      _continueFrom = (track: start, began: began, heard: heardMs);
    }
    _scheduleSave();
    return true;
  }

  Future<bool> restoreSession({bool autoPlay = false}) async {
    if (_tracks.isNotEmpty) return true;
    return _restore('last_session', autoPlay: autoPlay);
  }

  Future<bool> _restore(String key, {bool autoPlay = false}) async {
    final raw = (await _db.allSettings())[key];
    if (raw == null || raw.isEmpty) return false;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['at'] is int) lastPlayedAt ??= DateTime.fromMillisecondsSinceEpoch(data['at'] as int);
      final list = (data['tracks'] as List).map((m) => Track.fromMap((m as Map).cast<String, Object?>())).where((t) => t.fileExists).toList();
      if (list.isEmpty) return false;
      final index = (data['index'] as int).clamp(0, list.length - 1);
      // Restoring isn't listening yet, so it doesn't go into the history.
      await _loadQueue(record: false, () async {
        _replaced();
        _tracks = list;
        queue.add(_tracks.map(_item).toList());
        final original = (data['original'] as List?)?.cast<int>();
        final valid = original != null && original.length == list.length && original.every((i) => i >= 0 && i < list.length);
        _unshuffled = valid ? [for (final i in original) list[i]] : [];
        _setShuffled(valid);
        await player.setShuffleModeEnabled(false);
        await player
            .setAudioSources(list.map(_source).toList(),
                initialIndex: index, initialPosition: Duration(milliseconds: data['position'] as int? ?? 0))
            .timeout(const Duration(seconds: 20));
      });
      if (autoPlay) player.play();
      return true;
    } catch (_) {
      // Couldn't be opened (or took far too long): start with an empty queue
      // rather than a stuck one.
      _tracks = [];
      _unshuffled = [];
      queue.add(const []);
      mediaItem.add(null);
      unawaited(player.stop());
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
      _fadeGain = 0;
      await _applyVolume();
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
      if (_fadeGain > 0) return;
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
  Future<void> skipToNext() async {
    // Next during a preview: that's how it is stopped.
    if (_before != null) return _endPreview();
    await _ready(nextTrack);
    await player.seekToNext();
  }

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
      final i = player.currentIndex;
      await _ready(i == null || i < 1 ? null : _tracks[i - 1]);
      await player.seekToPrevious();
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    await _ready(_tracks[index]);
    await player.seek(Duration.zero, index: index);
    player.play();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final on = shuffleMode != AudioServiceShuffleMode.none;
    if (on == _shuffled) return;
    final heard = on ? await _heardTest() : null;
    final before = _before;
    if (before != null) {
      // During a preview: the queue that comes back is rearranged.
      if (before.current != null) {
        before.rearrange(_tailFor(on, before.tracks, before.index, before.waiting, before.unshuffled, heard), on: on);
      } else {
        before.shuffled = on;
      }
      _setShuffled(on);
      _scheduleSave();
      return;
    }
    final cur = player.currentIndex;
    if (_tracks.isEmpty || cur == null || cur >= _tracks.length) {
      _setShuffled(on);
      return;
    }
    final waiting = _pendingUpNext();
    final tail = _tailFor(on, _tracks, cur, waiting, _unshuffled, heard);
    _unshuffled = on ? List.of(_tracks) : [];
    await _replaceTail(cur, tail);
    _setShuffled(on);
  }

  /// What follows the song at [cur] with shuffle turned [on] or off.
  List<Track> _tailFor(bool on, List<Track> list, int cur, List<Track> waiting, List<Track> original, bool Function(Track)? heard) {
    // Only what comes after the playing song is rearranged: taking songs out
    // before it made the player (mpv) lose count, so every song showed one
    // ahead of the one playing.
    final head = list.sublist(0, cur + 1);
    bool queued(Track t) => waiting.any((w) => identical(w, t));
    if (on) return [...waiting, ...unheardFirst(list.sublist(cur + 1).where((t) => !queued(t)).toList()..shuffle(_random), heard)];
    return [
      ...waiting,
      for (final t in unshuffledQueue(original, list))
        if (!queued(t) && !head.any((h) => identical(h, t))) t,
    ];
  }

  /// Tells which songs were listened to, for shuffling; null when
  /// 沒播過的歌優先 is off or the log can't be read (plain shuffle then).
  Future<bool Function(Track)?> _heardTest() async {
    if (!unplayedFirst) return null;
    try {
      final ids = await _db.heardTracks();
      return (t) => ids.contains(t.id);
    } catch (_) {
      return null;
    }
  }

  /// Puts [tail] after the song at [cur], leaving it and everything before alone.
  Future<void> _replaceTail(int cur, List<Track> tail) async {
    _loadingQueue = true;
    try {
      if (cur + 1 < _tracks.length) await player.removeAudioSourceRange(cur + 1, _tracks.length);
      if (tail.isNotEmpty) await player.addAudioSources(tail.map(_source).toList());
      _tracks = [..._tracks.sublist(0, cur + 1), ...tail];
    } finally {
      _loadingQueue = false;
    }
    queue.add(_tracks.map(_item).toList());
    _scheduleSave();
  }

  void _setShuffled(bool on) {
    if (_shuffled == on) return;
    _shuffled = on;
    _shuffleChanges.add(on);
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
  Future<void> onTaskRemoved() async {
    if (_before != null) {
      // Closed during a preview: the app opens on the queue before it.
      await saveSession();
      await _endPreview();
    }
    await stop();
  }
}

/// Shuffled copy of [list] with the item at [current] moved to the front and,
/// given [heard], the items not heard yet right after it.
List<T> shuffledQueue<T>(List<T> list, int current, Random random, {bool Function(T)? heard}) {
  final rest = [for (var i = 0; i < list.length; i++) if (i != current) list[i]]..shuffle(random);
  return [list[current], ...unheardFirst(rest, heard)];
}

/// [list] with the items not [heard] yet ahead of the rest, each part in its
/// own order.
List<T> unheardFirst<T>(List<T> list, bool Function(T)? heard) =>
    heard == null ? list : [...list.where((t) => !heard(t)), ...list.where(heard)];

/// A random index in [list], among the items not [heard] yet while any are left.
int randomStart<T>(List<T> list, Random random, {bool Function(T)? heard}) {
  final unheard = [for (var i = 0; i < list.length; i++) if (heard != null && !heard(list[i])) i];
  return unheard.isEmpty ? random.nextInt(list.length) : unheard[random.nextInt(unheard.length)];
}

/// The pre-shuffle order for what is in [queue] now: items still queued keep
/// their [original] order; items added while shuffled go at the end.
List<T> unshuffledQueue<T>(List<T> original, List<T> queue) {
  final kept = [for (final t in original) if (queue.any((q) => identical(q, t))) t];
  final added = [for (final q in queue) if (!kept.any((t) => identical(t, q))) q];
  return [...kept, ...added];
}

/// [order] with [upNext] (songs queued by hand) moved right after [current].
List<T> withUpNext<T>(List<T> order, T current, List<T> upNext) {
  if (upNext.isEmpty) return order;
  final rest = [for (final t in order) if (!upNext.any((u) => identical(u, t))) t];
  final at = rest.indexWhere((t) => identical(t, current));
  return [...rest.sublist(0, at + 1), ...upNext, ...rest.sublist(at + 1)];
}

/// Volume part way ([t] from 0 to 1) through a fade; eased so it sounds even.
double fadeVolume(double from, double to, double t) {
  final eased = t * t * (3 - 2 * t);
  return (from + (to - from) * eased).clamp(0.0, 1.0);
}
