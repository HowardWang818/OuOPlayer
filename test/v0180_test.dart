import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/services/updater.dart';

void main() {
  // Shaped like what scripts/publish.ps1 uploads.
  final json = jsonDecode('''
  {
    "version": "0.18.1",
    "build": 41,
    "notes": "  修正一些問題  ",
    "released": "2026-10-25",
    "apks": {
      "arm64-v8a": {"path": "v0.18.1/OuOPlayer-0.18.1-arm64-v8a.apk", "sha256": "ABCDEF", "size": 65000000},
      "armeabi-v7a": {"path": "v0.18.1/OuOPlayer-0.18.1-armeabi-v7a.apk", "sha256": "123456", "size": 58000000}
    }
  }''') as Map<String, Object?>;

  test('latest.json is read', () {
    final info = UpdateInfo.fromJson(json);
    expect((info.version, info.build, info.notes), ('0.18.1', 41, '修正一些問題'));
    expect(info.apks['arm64-v8a']!.sha256, 'abcdef');
    expect(info.apks['armeabi-v7a']!.size, 58000000);
  });

  test('only a higher build number is an update', () {
    final info = UpdateInfo.fromJson(json);
    expect(info.isNewerThan(40), isTrue);
    expect(info.isNewerThan(41), isFalse);
    expect(info.isNewerThan(42), isFalse);
  });

  test('the phone gets the APK of its best ABI that exists', () {
    final info = UpdateInfo.fromJson(json);
    expect(info.apkFor(['arm64-v8a', 'armeabi-v7a', 'armeabi'])!.path, endsWith('arm64-v8a.apk'));
    expect(info.apkFor(['armeabi-v7a', 'armeabi'])!.path, endsWith('armeabi-v7a.apk'));
    expect(info.apkFor(['x86_64']), isNull);
  });
}
