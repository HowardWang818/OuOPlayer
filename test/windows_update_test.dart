import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/services/updater.dart';

void main() {
  test('versions compare as numbers', () {
    expect(isNewerVersion('0.23.0', '0.22.2'), isTrue);
    expect(isNewerVersion('0.22.10', '0.22.9'), isTrue);
    expect(isNewerVersion('1.0.0', '0.99.99'), isTrue);
    expect(isNewerVersion('0.22.2', '0.22.2'), isFalse);
    expect(isNewerVersion('0.22.1', '0.22.2'), isFalse);
    expect(isNewerVersion('0.23', '0.23.0'), isFalse);
  });

  test('the Windows file reads like an APK list, with no build number', () {
    final info = UpdateInfo.fromJson({
      'version': '0.23.1',
      'notes': ' 修正 ',
      'apks': {
        'windows': {'path': 'windows/v0.23.1/OuOPlayer-0.23.1-windows-setup.exe', 'sha256': 'ABC', 'size': 80},
      },
    });
    expect(info.build, 0);
    expect(info.notes, '修正');
    expect(info.apkFor(const ['windows'])?.sha256, 'abc');
    expect(info.apkFor(const ['arm64-v8a']), isNull);
  });

  test('a phone still goes by the build number', () {
    final info = UpdateInfo.fromJson({'version': '1.14.2', 'build': 79, 'apks': {}});
    expect(info.build, 79);
  });
}
