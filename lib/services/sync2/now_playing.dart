import 'dart:convert';

import '../../data/models/track.dart';
import '../sync/drive_client.dart';
import 'merge.dart';

/// {device: ms} as read from JSON.
Map<String, int> msByDevice(Object? j) => {
      if (j is Map)
        for (final e in j.entries)
          if (e.value is num) '${e.key}': (e.value as num).toInt(),
    };

/// 接續播放 (v1.12.0): what a device is playing — the queue (song names),
/// which song, where in it, shuffle / repeat — in `v2-now-<device>.json`,
/// so the other device can carry on from there.
class NowPlaying {
  const NowPlaying({
    required this.device,
    required this.deviceName,
    required this.at,
    required this.songs,
    required this.index,
    required this.positionMs,
    this.original,
    this.loop = 'off',
    this.began,
    this.heardMs = 0,
    this.parts,
    this.mark,
    this.seen = const {},
    this.session,
    this.playing = false,
    this.over = false,
  });

  final String device;
  final String deviceName;

  /// When it last played there.
  final int at;

  /// {t, a, al, ms} of each song in the queue, in play order.
  final List<Map<String, Object?>> songs;
  final int index;
  final int positionMs;

  /// Shuffled: the queue's order before shuffling (indexes into [songs]).
  final List<int>? original;
  final String loop;

  /// When the play of the current song began there, and how long it was
  /// heard (1.20.9): picked up here, it goes on as the same play.
  final int? began;
  final int heardMs;

  /// How long each device heard that play (1.23.0: the times add up).
  final Map<String, int>? parts;

  /// 1.23.0, 兩台各自播過: all that was really played there ([ResumeState.need]
  /// or more), ever, in ms. Null: sent by a version before that.
  final int? mark;

  /// The [mark] of each other device that was dealt with there (picked up,
  /// answered). Not merely downloaded: what is still to be chosen isn't seen.
  final Map<String, int> seen;

  /// The listening it belongs to, to ask once about it.
  final String? session;
  final bool playing;

  /// Given up there for another device's: not offered, not in the way.
  final bool over;

  bool get legacy => mark == null;

  /// What [seen] is counted in (before 1.23.0: when it last played).
  int get markOrAt => mark ?? at;

  /// Before 1.23.0 a file told no listening: the song's play stands in.
  String get sessionKey => session ?? '${began ?? at}';

  /// Playing there right now; an app that was killed stops saying so.
  bool playingAt(DateTime now) => playing && now.millisecondsSinceEpoch - at < const Duration(minutes: 3).inMilliseconds;

  NowPlaying copyWith({int? at, int? mark, Map<String, int>? seen, String? session, bool? playing, bool? over, Map<String, int>? parts}) => NowPlaying(
        device: device,
        deviceName: deviceName,
        at: at ?? this.at,
        songs: songs,
        index: index,
        positionMs: positionMs,
        original: original,
        loop: loop,
        began: began,
        heardMs: heardMs,
        parts: parts ?? this.parts,
        mark: mark ?? this.mark,
        seen: seen ?? this.seen,
        session: session ?? this.session,
        playing: playing ?? this.playing,
        over: over ?? this.over,
      );

  Map<String, Object?> get current => songs[index.clamp(0, songs.length - 1)];

  Map<String, Object?> toJson() => {
        'device': device,
        'name': deviceName,
        'at': at,
        'songs': songs,
        'index': index,
        'position': positionMs,
        if (original != null) 'original': original,
        'loop': loop,
        if (began != null) 'began': began,
        if (began != null) 'heard': heardMs,
        if (began != null && parts != null) 'parts': parts,
        if (mark != null) ...{'mark': mark, 'seen': seen, 'playing': playing, 'over': over},
        if (session != null) 'session': session,
      };

  static NowPlaying? fromJson(Map j) {
    final songs = [for (final s in (j['songs'] as List? ?? const [])) (s as Map).cast<String, Object?>()];
    if (songs.isEmpty) return null;
    return NowPlaying(
      device: '${j['device']}',
      deviceName: '${j['name'] ?? '另一台裝置'}',
      at: (j['at'] as num).toInt(),
      songs: songs,
      index: (j['index'] as num?)?.toInt() ?? 0,
      positionMs: (j['position'] as num?)?.toInt() ?? 0,
      original: (j['original'] as List?)?.cast<num>().map((n) => n.toInt()).toList(),
      loop: '${j['loop'] ?? 'off'}',
      began: (j['began'] as num?)?.toInt(),
      heardMs: (j['heard'] as num?)?.toInt() ?? 0,
      parts: j['parts'] is Map ? msByDevice(j['parts']) : null,
      mark: (j['mark'] as num?)?.toInt(),
      seen: msByDevice(j['seen']),
      session: j['session'] as String?,
      playing: j['playing'] == true,
      over: j['over'] == true,
    );
  }
}

/// What to do when another device played more recently ('sync_resume_mode',
/// set in 設定 → 同步 or by 記住我的選擇).
enum ResumeMode {
  ask,
  auto,
  never;

  static ResumeMode parse(String? v) => values.where((m) => m.name == v).firstOrNull ?? ask;
}

/// [choose]: both played apart.
enum ResumeStep { none, ask, load, choose }

/// What was last dealt with of another device: its [mark] then, this
/// device's own [mine] then, and whether it was [took] (picked up).
class Settled {
  const Settled({required this.mark, required this.mine, required this.session, required this.took});
  final int mark;
  final int mine;
  final String session;
  final bool took;

  Map<String, Object?> toJson() => {'mark': mark, 'mine': mine, 'session': session, 'took': took};

  factory Settled.fromJson(Map j) => Settled(
      mark: (j['mark'] as num?)?.toInt() ?? 0,
      mine: (j['mine'] as num?)?.toInt() ?? 0,
      session: '${j['session']}',
      took: j['took'] == true);
}

/// This device's side of 接續播放 (1.23.0). Which is newer isn't told by the
/// clocks: a device played since if its [mark] went on by [need] from the one
/// last dealt with here, and both played if it hadn't dealt with this one's.
class ResumeState {
  /// 累計 30 秒 is playing; less (a slip, a try) changes nothing for the others.
  static const need = 30000;

  /// Older is never offered.
  static const limit = Duration(hours: 12);

  /// All that was really played here, ever (only [run]s that reached [need]).
  int mark = 0;

  /// Played since the last pick-up, or since a queue replaced one that counted.
  int run = 0;

  /// When it last really played here.
  int? at;

  /// Given up for another device's.
  bool over = false;

  String? session;

  /// The last real progress here: what the others get, not a try.
  NowPlaying? snap;

  final settled = <String, Settled>{};

  /// device → the listening not to ask about again (不要, 取消).
  final quiet = <String, String>{};

  /// Goes up whenever what the others get changes; [sent]: the one that got through.
  int rev = 0;
  int sent = 0;

  bool get counts => run >= need;
  bool get pending => snap != null && rev != sent;

  /// [ms] more heard. The moment a run counts, all of it counts.
  void heard(int ms, int now) {
    final before = counts;
    run += ms;
    if (!counts) return;
    mark += before ? ms : run;
    at = now;
    over = false;
    rev++;
  }

  /// Dealt with: [o] picked up ([took]) or turned down.
  void settle(NowPlaying o, {required bool took}) {
    final before = settled[o.device];
    // An older one, kept and chosen later, takes nothing back.
    if (before != null && before.mark > o.markOrAt) return;
    settled[o.device] = Settled(mark: o.markOrAt, mine: mark, session: o.sessionKey, took: took);
    took ? quiet.remove(o.device) : quiet[o.device] = o.sessionKey;
    rev++;
  }

  /// The file the others read (null: never really played here).
  NowPlaying? toSend() => snap?.copyWith(
        at: at,
        mark: mark,
        session: session,
        over: over,
        seen: {for (final e in settled.entries) e.key: e.value.mark},
      );

  Map<String, Object?> toJson() => {
        'mark': mark,
        'run': run,
        'at': at,
        'over': over,
        'session': session,
        'snap': snap?.toJson(),
        'settled': {for (final e in settled.entries) e.key: e.value.toJson()},
        'quiet': quiet,
        'rev': rev,
        'sent': sent,
      };

  static ResumeState fromJson(Map j) {
    int n(Object? v) => (v as num?)?.toInt() ?? 0;
    final s = ResumeState()
      ..mark = n(j['mark'])
      ..run = n(j['run'])
      ..at = (j['at'] as num?)?.toInt()
      ..over = j['over'] == true
      ..session = j['session'] as String?
      ..snap = j['snap'] is Map ? NowPlaying.fromJson(j['snap'] as Map) : null
      ..rev = n(j['rev'])
      ..sent = n(j['sent']);
    for (final e in (j['settled'] as Map? ?? const {}).entries) {
      s.settled['${e.key}'] = Settled.fromJson(e.value as Map);
    }
    for (final e in (j['quiet'] as Map? ?? const {}).entries) {
      s.quiet['${e.key}'] = '${e.value}';
    }
    return s;
  }
}

/// What to do with the other devices' progress.
class ResumePlan {
  const ResumePlan(this.step, this.why, {this.offers = const [], this.expired = const [], this.both = false});
  final ResumeStep step;

  /// What decided it, for 'sync_resume_debug'.
  final String why;

  /// What played since on the others, newest first (also when nothing is
  /// asked now: kept for 換回).
  final List<NowPlaying> offers;

  /// Past [ResumeState.limit]: dealt with as that, without asking.
  final List<NowPlaying> expired;

  /// This device and another played apart.
  final bool both;
}

/// The other devices' states against this one's. [playingHere]: nothing is
/// asked or loaded while it plays. [lastPlayedHere], [asked]: only to read
/// what a version before 1.23.0 left.
ResumePlan resumePlan({
  required ResumeMode mode,
  required List<NowPlaying> others,
  required String me,
  required ResumeState state,
  required DateTime now,
  bool playingHere = false,
  DateTime? lastPlayedHere,
  String? asked,
}) {
  const need = ResumeState.need;
  if (mode == ResumeMode.never) return const ResumePlan(ResumeStep.none, 'set to never');
  final late = now.subtract(ResumeState.limit).millisecondsSinceEpoch;
  final since = <NowPlaying>[];
  final expired = <NowPlaying>[];
  for (final o in others) {
    if (o.over) continue;
    final s = state.settled[o.device];
    final bool played;
    if (o.legacy) {
      played = o.at > (s?.mark ?? 0) &&
          asked != '${o.device}:${o.at}' &&
          (s != null || state.mark > 0 || lastPlayedHere == null || o.at > lastPlayedHere.millisecondsSinceEpoch);
    } else {
      final gone = o.mark! - (s?.mark ?? 0);
      // Following one listening automatically: to where it stopped, exactly
      // (not once this one played since: that takes 30 seconds there too).
      final following =
          mode == ResumeMode.auto && s != null && s.took && s.session == o.sessionKey && state.mark - s.mine < need;
      played = gone >= need || (following && gone > 0);
    }
    if (!played) continue;
    (o.at < late ? expired : since).add(o);
  }
  // Three devices: one that another had picked up since is behind that one.
  bool saw(NowPlaying p, NowPlaying o) => !o.legacy && p.seen.containsKey(o.device) && o.mark! - p.seen[o.device]! < need;
  final offers = [
    for (final o in since)
      if (!since.any((p) => p.device != o.device && saw(p, o) && (!saw(o, p) || p.at > o.at))) o,
  ]..sort((a, b) => b.at.compareTo(a.at));

  if (offers.isEmpty) {
    final why = others.isEmpty
        ? 'nothing from another device'
        : expired.isNotEmpty
            ? 'older than 12 h: ${DateTime.fromMillisecondsSinceEpoch(expired.first.at)}'
            : 'this device is newer';
    return ResumePlan(ResumeStep.none, playingHere ? 'playing here' : why, expired: expired);
  }
  final minePlayed = !state.over && state.at != null && state.at! >= late;
  final both = offers.length > 1 ||
      (minePlayed &&
          offers.any((o) {
            final known = o.legacy ? state.settled[o.device]?.mine : o.seen[me];
            return state.mark - (known ?? 0) >= need;
          }));
  final id = offers.map((o) => '${o.device}:${o.sessionKey}').join(' ');
  final tag = both ? 'two' : 'one';
  ResumePlan plan(ResumeStep step, String why) => ResumePlan(step, why, offers: offers, expired: expired, both: both);

  if (playingHere) return plan(ResumeStep.none, both ? 'two: playing here' : 'playing here');
  bool silent(NowPlaying o) {
    if (state.quiet[o.device] == o.sessionKey) return true;
    // Picked up and still going there: asked again when it stops.
    if (mode == ResumeMode.auto && !both) return false;
    final s = state.settled[o.device];
    return s != null && s.took && s.session == o.sessionKey && o.playingAt(now);
  }

  if (offers.every(silent)) return plan(ResumeStep.none, 'already asked ($tag): $id');
  if (both) return plan(ResumeStep.choose, 'two: $id');
  return mode == ResumeMode.auto ? plan(ResumeStep.load, 'loaded: $id') : plan(ResumeStep.ask, 'asked: $id');
}

/// This device's songs for the other device's queue (null: not here), found
/// by their names or, for songs renamed here, by their first names
/// ([edits]: the track_edits rows).
List<Track?> queueHere(NowPlaying latest, List<Track> library, List<Map<String, Object?>> edits) {
  final byKey = <String, Track>{};
  for (final t in library) {
    byKey.putIfAbsent(songKey(t.title, t.artist), () => t);
  }
  final byId = {for (final t in library) t.id: t};
  for (final r in edits) {
    final t = byId[r['track_id']];
    if (t != null) byKey.putIfAbsent('${r['root']}', () => t);
  }
  return [for (final s in latest.songs) byKey[songKey('${s['t']}', '${s['a']}')]];
}

/// Reads and writes the `v2-now-*` files.
class NowPlayingStore {
  NowPlayingStore(this.drive);
  final DriveStore drive;
  String? _myId;

  Future<void> put(NowPlaying now) async {
    final name = 'v2-now-${now.device}.json';
    _myId ??= (await drive.list()).where((f) => f.name == name).firstOrNull?.id;
    try {
      _myId = await drive.upload(name, utf8.encode(jsonEncode(now.toJson())), id: _myId, mime: 'application/json');
    } catch (_) {
      // The file was removed meanwhile: a new one.
      _myId = await drive.upload(name, utf8.encode(jsonEncode(now.toJson())), mime: 'application/json');
    }
  }

  /// The other devices' latest, one each, newest first.
  Future<List<NowPlaying>> others(String me) async {
    final out = <String, NowPlaying>{};
    for (final f in await drive.list()) {
      if (!f.name.startsWith('v2-now-') || f.name == 'v2-now-$me.json') continue;
      try {
        final n = NowPlaying.fromJson(jsonDecode(utf8.decode(await drive.download(f.id))) as Map);
        if (n != null && n.at >= (out[n.device]?.at ?? 0)) out[n.device] = n;
      } catch (_) {}
    }
    return out.values.toList()..sort((a, b) => b.at.compareTo(a.at));
  }
}
