import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../config/demo.dart';
import '../config/update_config.dart';

/// One APK of a release (per ABI).
class UpdateApk {
  const UpdateApk(this.path, this.sha256, this.size);
  final String path;
  final String sha256;
  final int size;
}

/// latest.json: the newest version on the update server.
class UpdateInfo {
  const UpdateInfo({required this.version, required this.build, required this.notes, required this.apks});
  final String version;
  final int build;
  final String notes;

  /// ABI (arm64-v8a, armeabi-v7a, x86_64) → its APK.
  final Map<String, UpdateApk> apks;

  factory UpdateInfo.fromJson(Map<String, Object?> j) => UpdateInfo(
        version: j['version'] as String,
        build: (j['build'] as num).toInt(),
        notes: (j['notes'] as String? ?? '').trim(),
        apks: {
          for (final e in ((j['apks'] as Map?) ?? const {}).entries)
            if (e.value is Map)
              e.key as String: UpdateApk(
                (e.value as Map)['path'] as String,
                ((e.value as Map)['sha256'] as String).toLowerCase(),
                ((e.value as Map)['size'] as num?)?.toInt() ?? 0,
              ),
        },
      );

  bool isNewerThan(int build) => this.build > build;

  /// The APK for the first of the phone's ABIs (best first) that has one.
  UpdateApk? apkFor(List<String> abis) {
    for (final a in abis) {
      final apk = apks[a];
      if (apk != null) return apk;
    }
    return null;
  }
}

/// Checks the update server, downloads and verifies the APK, and hands it to
/// Android's installer. Android only for now.
class Updater {
  Updater({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: updateServer,
              headers: updateHeaders,
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(minutes: 5),
            ));

  final Dio _dio;
  static const _channel = MethodChannel('ouo/update');

  static bool get supported => Platform.isAndroid && !isDemo;

  /// This app's version name and build number (pubspec's number after +).
  static Future<({String name, int build})> current() async {
    final m = await _channel.invokeMapMethod<String, Object?>('version') ?? const {};
    // Split APKs add 1000 × ABI to the version code.
    return (name: m['name'] as String? ?? '', build: ((m['code'] as num?)?.toInt() ?? 0) % 1000);
  }

  static String explain(Object e) {
    if (e is DioException) {
      if (e.response?.statusCode == 429) return '更新伺服器忙碌中，請一分鐘後再試';
      if (e.response?.statusCode == 404) return '更新伺服器上還沒有可用的版本';
      if (e.type == DioExceptionType.connectionError || e.type == DioExceptionType.connectionTimeout) return '無法連線到更新伺服器，請檢查網路';
      return '更新伺服器回應錯誤（${e.response?.statusCode ?? e.type.name}）';
    }
    return '$e';
  }

  Future<UpdateInfo> latest() async {
    final res = await _dio.get<Map<String, dynamic>>('/latest.json', options: Options(responseType: ResponseType.json));
    return UpdateInfo.fromJson(res.data ?? const {});
  }

  /// The phone's ABIs, best first.
  static Future<List<String>> abis() async => (await _channel.invokeListMethod<String>('abis')) ?? const ['arm64-v8a'];

  /// The APK for this phone, downloaded into the cache and checked against
  /// its SHA-256. Older downloads are removed.
  Future<File> download(UpdateInfo info, {void Function(int got, int total)? onProgress, CancelToken? cancel}) async {
    final abis = await Updater.abis();
    final apk = info.apkFor(abis);
    if (apk == null) throw '這一版沒有適合這支手機的 APK（${abis.join(', ')}）';
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'updates'));
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, p.basename(apk.path)));
    await _dio.download('/${apk.path}', file.path, cancelToken: cancel, onReceiveProgress: (got, total) {
      onProgress?.call(got, total > 0 ? total : apk.size);
    });
    final hash = (await sha256.bind(file.openRead()).first).toString();
    if (hash != apk.sha256) {
      await file.delete();
      throw '下載的檔案不完整（檢查碼不符），請再試一次';
    }
    return file;
  }

  /// Whether Android lets OuOPlayer install apps (「安裝不明應用程式」).
  static Future<bool> canInstall() async => await _channel.invokeMethod<bool>('canInstall') ?? false;

  static Future<void> openInstallSettings() => _channel.invokeMethod('openInstallSettings');

  static Future<void> install(File apk) async {
    try {
      await _channel.invokeMethod('install', {'path': apk.path});
    } on PlatformException catch (e) {
      throw e.message ?? '無法開啟安裝畫面';
    }
  }
}
