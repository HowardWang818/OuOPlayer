import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/theme/app_theme.dart';
import 'package:ouoplayer/theme/looks.dart';
import 'package:ouoplayer/theme/themes.dart';
import 'package:ouoplayer/ui/widgets/vinyl_cover.dart';

import 'sync2_test.dart' show Device, FakeDrive;

void main() {
  test('the 外觀 choices come back from the settings', () {
    const l = Looks(
      background: PlayerBackground.blur,
      cover: CoverStyle.vinyl,
      lyricsAlign: LyricsAlign.center,
      density: ListDensity.compact,
      corners: Corners.square,
      pureBlack: true,
    );
    expect(Looks.fromSettings(l.toSettings()), l);
    expect(Looks.fromSettings(const {}), const Looks()); // before v1.17.0: as it was
    expect(const Looks().lyricsAlign, LyricsAlign.left);
    expect(Looks.fromSettings({'look_bg': 'nonsense'}).background, PlayerBackground.gradient);
    expect(l.toSettings().keys, Looks.keys);
  });

  test('corners scale every radius', () {
    expect(const Looks().radius(8), 8);
    expect(const Looks(corners: Corners.round).radius(8), 20);
    expect(const Looks(corners: Corners.round).radius(4), 12);
    expect(const Looks(corners: Corners.square).radius(8), lessThan(4));
    final input = AppTheme.build(presets.first.dark, looks: const Looks(corners: Corners.square)).inputDecorationTheme.border as OutlineInputBorder;
    expect(input.borderRadius.topLeft.x, lessThan(8));
  });

  test('pure black puts every dark theme on black and keeps it readable', () {
    for (final t in presets) {
      final p = t.dark.pureBlack();
      expect(p.bg, Colors.black, reason: t.name);
      expect(contrast(p.text, p.bg), greaterThanOrEqualTo(4.5), reason: t.name);
      expect(contrast(p.muted, p.bg), greaterThanOrEqualTo(4.5), reason: t.name);
      expect(contrast(p.onPlay, p.play), greaterThanOrEqualTo(3), reason: t.name);
      // Light themes stay as they are.
      expect(identical(t.light.pureBlack(), t.light), isTrue);
    }
    expect(AppTheme.build(presets.first.dark, looks: const Looks(pureBlack: true)).scaffoldBackgroundColor, Colors.black);
  });

  test('the 外觀 choices go to the other device with the theme', () async {
    final drive = FakeDrive();
    final phone = await Device.make('phone', drive), pc = await Device.make('pc', drive);
    for (final e in const Looks(cover: CoverStyle.vinyl, corners: Corners.round).toSettings().entries) {
      await phone.db.setSetting(e.key, e.value);
    }
    await phone.db.setSetting('color_theme_at', '100');
    for (var i = 0; i < 2; i++) {
      await phone.sync();
      await pc.sync();
    }
    final got = Looks.fromSettings(await pc.db.allSettings());
    expect(got.cover, CoverStyle.vinyl);
    expect(got.corners, Corners.round);
  });

  testWidgets('the record turns only while playing', (tester) async {
    Future<double> turnsAfter(bool playing) async {
      await tester.pumpWidget(MaterialApp(home: VinylCover(art: null, size: 200, playing: playing)));
      await tester.pump(const Duration(seconds: 5));
      return tester.widget<RotationTransition>(find.byType(RotationTransition)).turns.value;
    }

    expect(await turnsAfter(false), 0);
    expect(await turnsAfter(true), greaterThan(0));
    // Paused again: it stays where it got to.
    final at = await turnsAfter(false);
    await tester.pump(const Duration(seconds: 5));
    expect(tester.widget<RotationTransition>(find.byType(RotationTransition)).turns.value, at);
  });
}
