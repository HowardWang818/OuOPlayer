import 'package:flutter/material.dart';

export '../../widgets/setting_tiles.dart';

/// Windows: the categories sit one under the other on one page.
class SettingsOnOnePage extends InheritedWidget {
  const SettingsOnOnePage({super.key, required super.child});

  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SettingsOnOnePage>() != null;

  @override
  bool updateShouldNotify(SettingsOnOnePage oldWidget) => false;
}

/// One settings category opened from 設定 (like Spotify's settings).
class SettingsSectionPage extends StatelessWidget {
  const SettingsSectionPage({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (SettingsOnOnePage.of(context)) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
          child: Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
        ),
        ...children,
      ]);
    }
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: children),
    );
  }
}

/// A small heading inside a settings category.
Widget settingsSubheader(BuildContext context, String t) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(t, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
    );
