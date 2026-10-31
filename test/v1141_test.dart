import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/theme/app_theme.dart';
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

    testWidgets('takes the blue controls', (tester) async {
      final theme = AppTheme.blueControls(ThemeData.light());
      final context = await contextIn(tester, theme);
      expect(AppTheme.lightDesktop(context), isTrue);
      expect(AppTheme.control(context), AppColors.desktopLightPlay);
      expect(AppTheme.controlSymbol(context), Colors.white);
      expect(theme.colorScheme.primary, AppColors.desktopLightMain);
      expect(theme.sliderTheme.activeTrackColor, AppColors.desktopLightMain);
      expect(theme.sliderTheme.inactiveTrackColor, AppColors.desktopLightTrack);
      expect(theme.iconButtonTheme.style?.foregroundColor?.resolve({}), AppColors.desktopLightIcon);
    });

    testWidgets('a theme without them keeps its own colours', (tester) async {
      final context = await contextIn(tester, ThemeData.light());
      expect(AppTheme.lightDesktop(context), isFalse);
      expect(AppTheme.control(context), Theme.of(context).colorScheme.onSurface);
    });
  });
}
