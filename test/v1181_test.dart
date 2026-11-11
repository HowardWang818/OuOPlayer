import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/config/version.dart';
import 'package:ouoplayer/services/launcher_shortcuts.dart';
import 'package:ouoplayer/ui/pages/help_page.dart';
import 'package:ouoplayer/ui/pages/onboarding_page.dart';
import 'package:ouoplayer/ui/pages/privacy_page.dart';
import 'package:ouoplayer/ui/widgets/share_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('這版新功能', () {
    test('shows after an update, also from versions that never stored one', () {
      expect(whatsNewDue(firstRun: false, seenVersion: null), isTrue);
      expect(whatsNewDue(firstRun: false, seenVersion: '1.18.0'), isTrue);
      expect(whatsNewDue(firstRun: false, seenVersion: appVersion), isFalse);
    });

    test('not on a new install (the guide shows then)', () {
      expect(whatsNewDue(firstRun: true, seenVersion: null), isFalse);
    });
  });

  group('長按圖示的捷徑', () {
    test('three shortcuts in the app\'s own rounded icons', () {
      expect(launcherShortcutIcons.keys, ['shuffle', 'resume', 'search']);
      expect(launcherShortcutIcons['resume'], Icons.play_arrow_rounded);
    });

    test('drawn as a 432 px adaptive icon, theme colour behind white', () async {
      final png = await drawShortcutIcon(Icons.shuffle_rounded, const Color(0xFF3366FF), Colors.white);
      final codec = await ui.instantiateImageCodec(png);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, shortcutIconSize);
      expect(frame.image.height, shortcutIconSize);
      final data = (await frame.image.toByteData())!;
      // A corner is the background colour (full bleed for the launcher's shape).
      expect([data.getUint8(0), data.getUint8(1), data.getUint8(2), data.getUint8(3)], [0x33, 0x66, 0xFF, 0xFF]);
    });
  });

  group('分享', () {
    test('both shapes have the same fixed rounded corners', () {
      expect(shareCardRadius, greaterThan(0));
      final src = File('lib/ui/widgets/share_card.dart').readAsStringSync();
      expect(src, contains('Listen on OuOPlayer'));
      expect(src, isNot(contains('正在用 OuOPlayer 聽')));
    });

    test('a button beside ♥ on the player, not in the song menu', () {
      expect(File('lib/ui/pages/now_playing_page.dart').readAsStringSync(), contains('showShareCard'));
      expect(File('lib/ui/widgets/track_tile.dart').readAsStringSync(), isNot(contains('showShareCard')));
    });
  });

  group('文字', () {
    final files = [
      'lib/ui/pages/onboarding_page.dart',
      'lib/ui/pages/help_page.dart',
      'lib/ui/pages/privacy_page.dart',
      'lib/ui/pages/settings/about_settings.dart',
      'lib/ui/pages/settings/app_icon_setting.dart',
      'lib/ui/pages/settings/scrobble_section.dart',
      'lib/ui/widgets/share_card.dart',
      'lib/ui/widgets/empty_state.dart',
      'assets/whats_new.txt',
    ];

    test('new text never says 你, 你的 or 也', () {
      for (final f in files) {
        final quoted = RegExp(r"'([^'\n]*)'").allMatches(File(f).readAsStringSync()).map((m) => m.group(1)!);
        final lines = f.endsWith('.txt') ? File(f).readAsLinesSync() : quoted;
        for (final text in lines) {
          expect(text, isNot(contains('你')), reason: '$f: $text');
          expect(RegExp(r'[一-鿿]也|^也').hasMatch(text), isFalse, reason: '$f: $text');
        }
      }
    });

    test('the in-app privacy page no longer tells about the count', () {
      final all = PrivacyPage.sections.map((s) => '${s.$1}${s.$2}').join();
      expect(all, isNot(contains('匿名')));
      expect(all, isNot(contains('簡單說')));
    });

    test('About has no licences or count switch; App 圖示 is in 外觀', () {
      final about = File('lib/ui/pages/settings/about_settings.dart').readAsStringSync();
      expect(about, isNot(contains('showLicensePage')));
      expect(about, isNot(contains('UsageStats')));
      expect(about, isNot(contains('AppIconSetting')));
      expect(File('lib/ui/pages/settings/appearance_settings.dart').readAsStringSync(), contains('AppIconSetting'));
    });

    test('Help covers copying links and Soundiiz', () {
      final titles = HelpPage.sections.map((s) => s.$2).toList();
      expect(titles, ['下載歌曲', '轉換 Spotify 等歌單']);
      expect(HelpPage.sections[1].$3.join(), contains('soundiiz.com'));
    });
  });

  test('the splash screen is only the background', () {
    const res = 'android/app/src/main/res';
    expect(File('$res/drawable/launch_background.xml').readAsStringSync(), isNot(contains('bitmap')));
    for (final d in ['values-v31', 'values-night-v31']) {
      expect(File('$res/$d/styles.xml').readAsStringSync(), contains('@drawable/splash_none'));
    }
  });
}
