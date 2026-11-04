import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/theme/app_theme.dart';
import 'package:ouoplayer/theme/themes.dart';
import 'package:ouoplayer/ui/pages/queue_page.dart';

void main() {
  test('the songs before the one playing are the ones hidden', () {
    expect(QueueList.played(null, 5), 0);
    expect(QueueList.played(0, 5), 0);
    expect(QueueList.played(3, 5), 3);
    // The song playing always stays on the list.
    expect(QueueList.played(9, 5), 4);
    expect(QueueList.played(0, 0), 0);
  });

  group('the light player', () {
    Future<BuildContext> contextIn(WidgetTester tester, ThemeData theme) async {
      late BuildContext context;
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Builder(builder: (c) {
          context = c;
          return const SizedBox();
        }),
      ));
      return context;
    }

    testWidgets('晴空 light takes the blue controls (phone too since v1.16.0)', (tester) async {
      final theme = AppTheme.build(presets.first.light);
      final context = await contextIn(tester, theme);
      expect(AppTheme.colouredControls(context), isTrue);
      expect(AppTheme.control(context), const Color(0xFF0B7FAE));
      expect(AppTheme.controlSymbol(context), Colors.white);
      expect(theme.colorScheme.primary, const Color(0xFF0B93C4));
      expect(theme.sliderTheme.activeTrackColor, const Color(0xFF0B93C4));
      expect(theme.sliderTheme.inactiveTrackColor, const Color(0xFFE2E8F0));
      expect(theme.iconButtonTheme.style?.foregroundColor?.resolve({}), const Color(0xFF64748B));
    });

    testWidgets('a dark theme keeps a light play button', (tester) async {
      final context = await contextIn(tester, AppTheme.build(presets.first.dark));
      expect(AppTheme.colouredControls(context), isFalse);
      expect(AppTheme.control(context), Colors.white);
    });
  });
}
