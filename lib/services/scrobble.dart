import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../config/lastfm_config.dart';
import '../config/version.dart';
import '../data/db/database.dart';
import '../data/models/track.dart';

/// One song heard, waiting to be sent.
class Heard {
  const Heard({required this.title, required this.artist, this.album, required this.at, this.seconds});
  final String title;
  final String artist;
  final String? album;
  final DateTime at;
  final int? seconds;

  factory Heard.of(Track t, DateTime at) => Heard(
        title: t.title,
        artist: t.artist,
        album: t.album.isEmpty ? null : t.album,
        at: at,
        seconds: t.durationMs == null ? null : t.durationMs! ~/ 1000,
      );

  Map<String, Object?> toJson() => {'t': title, 'a': artist, 'al': album, 'ts': at.millisecondsSinceEpoch ~/ 1000, 'd': seconds};

  factory Heard.fromJson(Map m) => Heard(
        title: '${m['t']}',
        artist: '${m['a']}',
        album: m['al'] as String?,
        at: DateTime.fromMillisecondsSinceEpoch((m['ts'] as num).toInt() * 1000),
        seconds: (m['d'] as num?)?.toInt(),
      );
}

/// Something went wrong that retrying won't fix (the sign-in is gone).
class ScrobbleSignedOut implements Exception {
  const ScrobbleSignedOut();
}

/// A place plays are recorded: Last.fm or ListenBrainz.
abstract class ScrobbleService {
  String get id;
  Future<void> nowPlaying(Heard h);
  Future<void> submit(List<Heard> batch);
}

/// Last.fm (needs the API key and secret, lastfm_config.dart).
class LastFm implements ScrobbleService {
  LastFm(this.session, {Dio? dio}) : _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 15)));
  final String session;
  final Dio _dio;
  static const _api = 'https://ws.audioscrobbler.com/2.0/';

  @override
  String get id => 'lastfm';

  /// Last.fm's signature: md5 of the sorted parameters and the secret.
  static String sign(Map<String, String> params, String secret) {
    final keys = params.keys.where((k) => k != 'format' && k != 'callback').toList()..sort();
    return md5.convert(utf8.encode('${keys.map((k) => '$k${params[k]}').join()}$secret')).toString();
  }

  static Map<String, String> signed(Map<String, String> params) =>
      {...params, 'api_key': lastFmKey, 'api_sig': sign({...params, 'api_key': lastFmKey}, lastFmSecret), 'format': 'json'};

  static Future<Map> _call(Dio dio, Map<String, String> params, {bool post = false}) async {
    final res = post
        ? await dio.post<Map>(_api, data: signed(params), options: Options(contentType: Headers.formUrlEncodedContentType, validateStatus: (_) => true))
        : await dio.get<Map>(_api, queryParameters: signed(params), options: Options(validateStatus: (_) => true));
    final body = res.data ?? const {};
    final error = body['error'];
    if (error == 9 || error == 4 || error == 14) throw const ScrobbleSignedOut();
    if (error != null) throw 'Last.fm：${body['message'] ?? error}';
    return body;
  }

  /// Sign-in, step 1: a token, then the page where the user allows it.
  static Future<(String token, String url)> startSignIn({Dio? dio}) async {
    final body = await _call(dio ?? Dio(), {'method': 'auth.getToken'});
    final token = '${body['token']}';
    return (token, 'https://www.last.fm/api/auth/?api_key=$lastFmKey&token=$token');
  }

  /// Step 2, after the user allowed it in the browser: (session key, name).
  static Future<(String, String)> finishSignIn(String token, {Dio? dio}) async {
    final body = await _call(dio ?? Dio(), {'method': 'auth.getSession', 'token': token});
    final s = body['session'] as Map;
    return ('${s['key']}', '${s['name']}');
  }

  @override
  Future<void> nowPlaying(Heard h) => _call(_dio, {
        'method': 'track.updateNowPlaying',
        'artist': h.artist,
        'track': h.title,
        if (h.album != null) 'album': h.album!,
        if (h.seconds != null) 'duration': '${h.seconds}',
        'sk': session,
      }, post: true);

  @override
  Future<void> submit(List<Heard> batch) async {
    final p = <String, String>{'method': 'track.scrobble', 'sk': session};
    for (var i = 0; i < batch.length; i++) {
      final h = batch[i];
      p['artist[$i]'] = h.artist;
      p['track[$i]'] = h.title;
      p['timestamp[$i]'] = '${h.at.millisecondsSinceEpoch ~/ 1000}';
      if (h.album != null) p['album[$i]'] = h.album!;
      if (h.seconds != null) p['duration[$i]'] = '${h.seconds}';
    }
    await _call(_dio, p, post: true);
  }
}

/// ListenBrainz (the user's own token from listenbrainz.org/settings).
class ListenBrainz implements ScrobbleService {
  ListenBrainz(this.token, {Dio? dio}) : _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 15)));
  final String token;
  final Dio _dio;
  static const _api = 'https://api.listenbrainz.org/1';

  @override
  String get id => 'listenbrainz';

  static Map<String, Object?> listen(Heard h, {bool withTime = true}) => {
        if (withTime) 'listened_at': h.at.millisecondsSinceEpoch ~/ 1000,
        'track_metadata': {
          'artist_name': h.artist,
          'track_name': h.title,
          if (h.album != null) 'release_name': h.album,
          'additional_info': {
            if (h.seconds != null) 'duration_ms': h.seconds! * 1000,
            'media_player': 'OuOPlayer',
            'submission_client': 'OuOPlayer',
            'submission_client_version': appVersion,
          },
        },
      };

  Future<void> _post(Map<String, Object?> body) async {
    final res = await _dio.post<Object?>('$_api/submit-listens',
        data: body, options: Options(headers: {'Authorization': 'Token $token'}, validateStatus: (_) => true));
    if (res.statusCode == 401) throw const ScrobbleSignedOut();
    if ((res.statusCode ?? 500) >= 300) throw 'ListenBrainz：${res.statusCode}';
  }

  /// The user name for [token], or null when it isn't valid.
  static Future<String?> check(String token, {Dio? dio}) async {
    final res = await (dio ?? Dio()).get<Map>('$_api/validate-token',
        options: Options(headers: {'Authorization': 'Token $token'}, validateStatus: (_) => true));
    final body = res.data ?? const {};
    return body['valid'] == true ? '${body['user_name']}' : null;
  }

  @override
  Future<void> nowPlaying(Heard h) => _post({
        'listen_type': 'playing_now',
        'payload': [listen(h, withTime: false)],
      });

  @override
  Future<void> submit(List<Heard> batch) => _post({
        'listen_type': batch.length == 1 ? 'single' : 'import',
        'payload': [for (final h in batch) listen(h)],
      });
}

/// 播放記錄: songs heard long enough go to Last.fm and/or ListenBrainz;
/// without a connection they wait (per service) and go later.
class Scrobbler {
  Scrobbler(this.db, {this.make});
  final AppDatabase db;

  /// Tests: the services to use instead of the real ones.
  final List<ScrobbleService> Function(Map<String, String> settings)? make;

  static const lastFmSessionKey = 'lastfm_session';
  static const lastFmUserKey = 'lastfm_user';
  static const listenBrainzKey = 'listenbrainz_token';
  static const listenBrainzUserKey = 'listenbrainz_user';
  static String queueKey(String service) => 'scrobble_queue_$service';

  /// Kept while offline, oldest dropped past this.
  static const maxQueued = 1000;

  /// Counts as heard: longer than 30 seconds, and played half of it or 4
  /// minutes, whichever comes first (the rule Last.fm and ListenBrainz use).
  static bool counts(Duration length, Duration heard) {
    if (length <= const Duration(seconds: 30)) return false;
    final half = length ~/ 2;
    return heard >= (half < const Duration(minutes: 4) ? half : const Duration(minutes: 4));
  }

  List<ScrobbleService> _services(Map<String, String> s) {
    if (make != null) return make!(s);
    return [
      if (lastFmAvailable && (s[lastFmSessionKey] ?? '').isNotEmpty) LastFm(s[lastFmSessionKey]!),
      if ((s[listenBrainzKey] ?? '').isNotEmpty) ListenBrainz(s[listenBrainzKey]!),
    ];
  }

  Future<void> _signedOut(String service) async {
    if (service == 'lastfm') {
      await db.setSetting(lastFmSessionKey, '');
      await db.setSetting(lastFmUserKey, '');
    } else {
      await db.setSetting(listenBrainzKey, '');
      await db.setSetting(listenBrainzUserKey, '');
    }
    await db.setSetting(queueKey(service), '');
  }

  Future<void> nowPlaying(Track t) async {
    final s = await db.allSettings();
    for (final svc in _services(s)) {
      try {
        await svc.nowPlaying(Heard.of(t, DateTime.now()));
      } on ScrobbleSignedOut {
        await _signedOut(svc.id);
      } catch (_) {}
    }
  }

  Future<void> heard(Track t, DateTime at) async {
    final s = await db.allSettings();
    final services = _services(s);
    for (final svc in services) {
      final q = _queue(s, svc.id)..add(Heard.of(t, at));
      await _save(svc.id, q);
    }
    await flush();
  }

  List<Heard> _queue(Map<String, String> s, String service) {
    try {
      return [for (final m in jsonDecode(s[queueKey(service)] ?? '[]') as List) Heard.fromJson(m as Map)];
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(String service, List<Heard> q) async {
    final kept = q.length > maxQueued ? q.sublist(q.length - maxQueued) : q;
    await db.setSetting(queueKey(service), jsonEncode([for (final h in kept) h.toJson()]));
  }

  /// Sends what waits, 50 at a time (Last.fm's limit). Never throws.
  Future<void> flush() async {
    final s = await db.allSettings();
    for (final svc in _services(s)) {
      var q = _queue(s, svc.id);
      try {
        while (q.isNotEmpty) {
          final batch = q.take(50).toList();
          await svc.submit(batch);
          q = q.sublist(batch.length);
          await _save(svc.id, q);
        }
      } on ScrobbleSignedOut {
        await _signedOut(svc.id);
      } catch (_) {}
    }
  }

  /// Songs waiting to be sent to [service].
  Future<int> waiting(String service) async => _queue(await db.allSettings(), service).length;
}
