import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:rapidfuzz/rapidfuzz.dart' as fuzz;

import 'artists.dart';
import 'song_matcher.dart';

/// Artist photos from Deezer's public API (free, no key or account; only the
/// artist's name is sent). Saved next to the cover cache so Android Auto
/// can show them too, and looked up one at a time, a second apart.
class ArtistImages {
  ArtistImages({Dio? dio}) : _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 10), receiveTimeout: const Duration(seconds: 20)));

  final Dio _dio;

  /// "Not on Deezer" is remembered this long, then asked again.
  static const notFoundFor = Duration(days: 14);

  static Directory? _dir;
  static Map<String, dynamic> _index = {};
  static Future<void>? _loading;
  Future<void> _queue = Future.value();

  static Future<Directory> folder() async {
    if (_dir != null) return _dir!;
    final d = Directory(p.join((await getApplicationSupportDirectory()).path, 'art', 'artists'));
    await d.create(recursive: true);
    return _dir = d;
  }

  static File _indexFile(Directory d) => File(p.join(d.path, 'index.json'));

  static Future<void> _load() => _loading ??= () async {
        final f = _indexFile(await folder());
        if (f.existsSync()) {
          try {
            _index = (jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>();
          } catch (_) {}
        }
      }();

  static String _key(String name) => foldText(name);

  /// The saved photo of [name], if one was found before (no network). A
  /// picture the user chose wins over the automatic one.
  static String? cached(String name) {
    final e = _index[_key(name)];
    if (e is! Map) return null;
    for (final f in [e['custom'], e['file']]) {
      if (f is! String) continue;
      final path = p.join(_dir?.path ?? '', f);
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  /// Whether the user chose [name]'s picture.
  static bool hasCustom(String name) {
    final e = _index[_key(name)];
    return e is Map && e['custom'] is String;
  }

  static Future<void> _save() async => _indexFile(await folder()).writeAsString(jsonEncode(_index));

  static String _fileName(String name, String ext) =>
      'custom_${_key(name).hashCode.toUnsigned(32).toRadixString(16)}_${DateTime.now().millisecondsSinceEpoch}$ext';

  static Future<void> _setCustomBytes(String name, List<int> bytes, String ext) async {
    await _load();
    final dir = await folder();
    await _deleteCustomFile(name);
    // A new file name each time so the old picture isn't shown from the image cache.
    final file = _fileName(name, ext);
    await File(p.join(dir.path, file)).writeAsBytes(bytes);
    final e = Map<String, dynamic>.from((_index[_key(name)] as Map?) ?? const {});
    _index[_key(name)] = e..['custom'] = file;
    await _save();
  }

  /// Uses the image at [path] (copied into the app) as [name]'s picture.
  static Future<void> setCustomFile(String name, String path) async =>
      _setCustomBytes(name, await File(path).readAsBytes(), p.extension(path).toLowerCase());

  /// Downloads [url] (one of [candidates]) as [name]'s picture.
  Future<void> setCustomUrl(String name, String url) async {
    final bytes = await _dio.get<List<int>>(url, options: Options(responseType: ResponseType.bytes));
    await _setCustomBytes(name, bytes.data ?? const [], '.jpg');
  }

  static Future<void> _deleteCustomFile(String name) async {
    final e = _index[_key(name)];
    if (e is! Map || e['custom'] is! String) return;
    try {
      await File(p.join((await folder()).path, e['custom'] as String)).delete();
    } catch (_) {}
  }

  /// Back to the automatic photo.
  static Future<void> removeCustom(String name) async {
    await _load();
    await _deleteCustomFile(name);
    final e = _index[_key(name)];
    if (e is Map) e.remove('custom');
    await _save();
  }

  /// After a rename: the chosen picture goes with the artist's new name.
  static Future<void> moveCustom(String from, String to) async {
    await _load();
    final e = _index[_key(from)];
    if (_key(from) == _key(to) || e is! Map || e['custom'] is! String || hasCustom(to)) return;
    final file = e.remove('custom');
    final target = Map<String, dynamic>.from((_index[_key(to)] as Map?) ?? const {});
    _index[_key(to)] = target..['custom'] = file;
    await _save();
  }

  /// Deezer artists that might be [name], for the user to choose from.
  Future<List<(String, String)>> candidates(String name) async {
    final res = await _dio.get<Map<String, dynamic>>('https://api.deezer.com/search/artist', queryParameters: {'q': name, 'limit': 12});
    return [
      for (final a in (res.data?['data'] as List? ?? const []).whereType<Map>())
        if ((a['picture_xl'] ?? a['picture_big']) case final String pic when pic.isNotEmpty && !pic.contains('/artist//'))
          (a['name'] as String? ?? '', pic),
    ];
  }

  /// [name]'s photo: from the cache, else looked up on Deezer when [online].
  Future<String?> image(String name, {required bool online}) async {
    await _load();
    final hit = cached(name);
    if (hit != null) return hit;
    final e = _index[_key(name)];
    if (e is Map && e['none'] == true) {
      final at = DateTime.fromMillisecondsSinceEpoch((e['at'] as int?) ?? 0);
      if (DateTime.now().difference(at) < notFoundFor) return null;
    }
    if (!online || name == '未知演出者') return null;
    // One request at a time, a second apart.
    final c = Completer<String?>();
    _queue = _queue.then((_) async {
      try {
        c.complete(await _fetch(name));
      } catch (_) {
        c.complete(null);
      }
      await Future.delayed(const Duration(seconds: 1));
    });
    return c.future;
  }

  Future<String?> _fetch(String name) async {
    final res = await _dio.get<Map<String, dynamic>>('https://api.deezer.com/search/artist', queryParameters: {'q': name, 'limit': 10});
    final list = (res.data?['data'] as List? ?? const []).whereType<Map>().toList();
    final best = pick(name, [for (final a in list) (a['name'] as String? ?? '', a['picture_xl'] as String? ?? a['picture_big'] as String?)]);
    final dir = await folder();
    final custom = (_index[_key(name)] as Map?)?['custom'];
    if (best == null) {
      _index[_key(name)] = {'none': true, 'at': DateTime.now().millisecondsSinceEpoch, if (custom != null) 'custom': custom};
    } else {
      final bytes = await _dio.get<List<int>>(best, options: Options(responseType: ResponseType.bytes));
      final file = '${_key(name).hashCode.toUnsigned(32).toRadixString(16)}.jpg';
      await File(p.join(dir.path, file)).writeAsBytes(bytes.data ?? const []);
      _index[_key(name)] = {'file': file, if (custom != null) 'custom': custom};
    }
    await _indexFile(dir).writeAsString(jsonEncode(_index));
    return best == null ? null : cached(name);
  }

  /// The photo of the Deezer artist whose name really is [name] (any built-in
  /// spelling, width, case, word order); never a 「close enough」 stranger.
  @visibleForTesting
  static String? pick(String name, List<(String, String?)> results) {
    final wanted = {foldText(name), ...knownSpellings(name)};
    for (final (n, picture) in results) {
      if (picture == null || picture.isEmpty || picture.contains('/artist//')) continue;
      final f = foldText(n);
      if (wanted.contains(f) || knownSpellings(n).any(wanted.contains)) return picture;
      if (fuzz.tokenSortRatio(spacedText(n), spacedText(name)) >= 98 && spacedText(name).contains(' ')) return picture;
    }
    return null;
  }

  /// Forgets the Deezer photos (儲存空間 → 清除); pictures the user chose stay.
  static Future<void> clear() async {
    await _load();
    final d = await folder();
    final kept = <String, dynamic>{
      for (final e in _index.entries)
        if (e.value is Map && (e.value as Map)['custom'] is String) e.key: {'custom': (e.value as Map)['custom']},
    };
    final keep = {for (final v in kept.values) (v as Map)['custom'] as String};
    await for (final f in d.list(followLinks: false)) {
      if (f is File && !keep.contains(p.basename(f.path))) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
    _index = kept;
    await _save();
  }
}
