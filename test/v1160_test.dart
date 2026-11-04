import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/app.dart' show rootNavigatorKey;
import 'package:ouoplayer/providers/theme_provider.dart';
import 'package:ouoplayer/theme/themes.dart';
import 'package:ouoplayer/ui/widgets/dialogs.dart';

import 'sync2_test.dart' show Device, FakeDrive;

void main() {
  group('colour themes', () {
    final seeds = [0xFF1DBEEF, 0xFFFF0000, 0xFFFFFF00, 0xFF00FF00, 0xFF0000FF, 0xFF808080, 0xFFFFC0CB, 0xFF101010, 0xFFF0F0F0];
    final all = [...presets, for (final s in seeds) ColorTheme.custom(Color(s))];

    test('every theme reads well in both modes', () {
      for (final t in all) {
        for (final p in [t.dark, t.light]) {
          final where = '${t.name} ${p.dark ? 'dark' : 'light'}';
          expect(contrast(p.text, p.bg), greaterThanOrEqualTo(4.5), reason: '$where text');
          expect(contrast(p.muted, p.bg), greaterThanOrEqualTo(4.5), reason: '$where muted text');
          expect(contrast(p.main, p.bg), greaterThanOrEqualTo(3), reason: '$where main colour');
          expect(contrast(p.onPlay, p.play), greaterThanOrEqualTo(3), reason: '$where play symbol');
          expect(contrast(p.onMain, p.main), greaterThanOrEqualTo(3), reason: '$where text on the main colour');
        }
        expect(t.dark.dark, isTrue, reason: t.name);
        expect(t.light.dark, isFalse, reason: t.name);
      }
    });

    test('晴空 keeps the colours OuOPlayer had', () {
      final t = presets.first;
      expect(t.id, ColorTheme.defaultId);
      expect(t.dark.bg, const Color(0xFF0E0E0E));
      expect(t.dark.main, const Color(0xFF1DBEEF));
      expect(t.light.main, const Color(0xFF0B93C4));
      expect(t.light.play, const Color(0xFF0B7FAE));
      expect(t.light.bar, const Color(0xFFF1F8FE));
    });

    test('ids are unique and unknown ones fall back to 晴空', () {
      expect(presets.map((t) => t.id).toSet(), hasLength(presets.length));
      expect(presets.length, 13);
      expect(ColorTheme.byId('nope').id, ColorTheme.defaultId);
      expect(ColorTheme.byId('custom').id, ColorTheme.defaultId); // no colour saved
      expect(ColorTheme.byId('custom', custom: const Color(0xFFEC4899)).id, 'custom');
    });

    test('a choice survives the settings and a sync file', () {
      final c = ThemeChoice.fromSettings({'color_theme': 'custom', 'color_theme_custom': 'ffec4899', 'color_theme_at': '5'});
      expect(c.theme.id, 'custom');
      final back = ThemeChoice.fromJson(c.toJson())!;
      expect(back.id, 'custom');
      expect(back.custom, const Color(0xFFEC4899));
      expect(back.at, 5);
    });
  });

  test('the theme chosen last reaches the other device', () async {
    final drive = FakeDrive();
    final phone = await Device.make('phone', drive), pc = await Device.make('pc', drive);
    var repainted = 0;
    pc.engine.onThemeChanged = () => repainted++;
    Future<void> settle() async {
      for (var i = 0; i < 2; i++) {
        await phone.sync();
        await pc.sync();
      }
    }

    Future<void> choose(Device d, String id, int at, {String? custom}) async {
      await d.db.setSetting('color_theme', id);
      if (custom != null) await d.db.setSetting('color_theme_custom', custom);
      await d.db.setSetting('color_theme_at', '$at');
    }

    await choose(phone, 'nord', 100);
    await settle();
    expect((await pc.db.allSettings())['color_theme'], 'nord');
    expect(repainted, 1);

    await choose(pc, 'custom', 200, custom: 'ffec4899');
    await settle();
    final s = await phone.db.allSettings();
    expect(s['color_theme'], 'custom');
    expect(s['color_theme_custom'], 'ffec4899');
    expect(repainted, 1); // the pc's own choice doesn't come back to it

    // Turned off on the pc: it keeps its own.
    await pc.db.setSetting('sync_theme', 'false');
    await choose(phone, 'sakura', 300);
    await settle();
    expect((await pc.db.allSettings())['color_theme'], 'custom');
  });

  testWidgets('a message from the root context still shows at the top', (tester) async {
    await tester.pumpWidget(MaterialApp(navigatorKey: rootNavigatorKey, home: const Scaffold(body: SizedBox.expand())));
    toast(rootNavigatorKey.currentContext!, '已把 3 首歌的歌名寫進檔案');
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
    final text = find.text('已把 3 首歌的歌名寫進檔案');
    expect(text, findsOneWidget);
    expect(tester.getCenter(text).dy, lessThan(200));
    await tester.pump(const Duration(seconds: 5));
  });
}
