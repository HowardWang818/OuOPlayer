import 'package:flutter/material.dart';

/// One settings category opened from 設定 (like Spotify's settings).
class SettingsSectionPage extends StatelessWidget {
  const SettingsSectionPage({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: ListView(padding: const EdgeInsets.only(bottom: 32), children: children),
      );
}

/// A small heading inside a settings category.
Widget settingsSubheader(BuildContext context, String t) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(t, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
    );
