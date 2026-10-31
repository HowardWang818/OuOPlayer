import 'dart:convert';

import '../sync/drive_client.dart';

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

enum ResumeStep { none, ask, load }

/// Whether [latest] (the other devices' newest state) is picked up here;
/// [why] says what decided it, for 'sync_resume_debug'.
({ResumeStep step, String why}) resumeStep({
  required ResumeMode mode,
  required NowPlaying? latest,
  required DateTime now,
  required DateTime? lastPlayedHere,
  required bool playingHere,
  required String? asked,
}) {
  if (mode == ResumeMode.never) return (step: ResumeStep.none, why: 'set to never');
  if (playingHere) return (step: ResumeStep.none, why: 'playing here');
  if (latest == null) return (step: ResumeStep.none, why: 'nothing from another device');
  final at = DateTime.fromMillisecondsSinceEpoch(latest.at);
  if (now.difference(at) > const Duration(hours: 12)) return (step: ResumeStep.none, why: 'older than 12 h: $at');
  if (lastPlayedHere != null && !at.isAfter(lastPlayedHere)) return (step: ResumeStep.none, why: 'this device is newer: $at <= $lastPlayedHere');
  final seen = '${latest.device}:${latest.at}';
  if (asked == seen) return (step: ResumeStep.none, why: 'already asked: $seen');
  return mode == ResumeMode.auto ? (step: ResumeStep.load, why: 'loaded: $seen') : (step: ResumeStep.ask, why: 'asked: $seen');
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

  /// The other devices' latest, newest first.
  Future<List<NowPlaying>> others(String me) async {
    final out = <NowPlaying>[];
    for (final f in await drive.list()) {
      if (!f.name.startsWith('v2-now-') || f.name == 'v2-now-$me.json') continue;
      try {
        final n = NowPlaying.fromJson(jsonDecode(utf8.decode(await drive.download(f.id))) as Map);
        if (n != null) out.add(n);
      } catch (_) {}
    }
    return out..sort((a, b) => b.at.compareTo(a.at));
  }
}
