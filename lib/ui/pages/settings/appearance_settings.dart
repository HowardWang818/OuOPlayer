import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';
import '../../../providers/theme_provider.dart';
import '../../../theme/themes.dart';
import '../../widgets/song_font.dart';
import 'section_page.dart';

/// 外觀: light / dark, the colour theme, the song-title font.
class AppearanceSettingsPage extends ConsumerWidget {
  const AppearanceSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(settingsProvider.select((s) => s.themeMode));
    final theme = ref.watch(themeChoiceProvider).theme;
    return SettingsSectionPage(title: '外觀', children: [
      const SettingTile(leading: Icon(Icons.contrast), title: Text('深色／淺色'), subtitle: Text('每個主題都有深色和淺色')),
      Padding(
        padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
        child: SegmentedButton<ThemeMode>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: ThemeMode.dark, label: Text('深色'), icon: Icon(Icons.dark_mode_outlined)),
            ButtonSegment(value: ThemeMode.light, label: Text('淺色'), icon: Icon(Icons.light_mode_outlined)),
          ],
          selected: {mode == ThemeMode.light ? ThemeMode.light : ThemeMode.dark},
          onSelectionChanged: (v) => ref.read(settingsProvider.notifier).setTheme(v.first),
        ),
      ),
      SettingTile(
        action: '選擇',
        leading: const Icon(Icons.palette_outlined),
        title: const Text('主題'),
        subtitle: Text(theme.name),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ThemePage())),
      ),
      SettingTile(
        leading: const Icon(Icons.font_download_outlined),
        title: const Text('歌名字體'),
        subtitle: Text(Platform.isWindows ? '播放條、右側欄、佇列和播放頁的歌名與歌手' : '播放條、佇列和播放頁的歌名'),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
        child: SegmentedButton<SongFont>(
          showSelectedIcon: false,
          segments: [for (final f in SongFont.available) ButtonSegment(value: f, label: Text(f.label))],
          selected: {ref.watch(songFontProvider)},
          onSelectionChanged: (v) => ref.read(songFontProvider.notifier).set(v.first),
        ),
      ),
    ]);
  }
}

/// 外觀 → 主題: every theme in both modes; tap one to use it.
class ThemePage extends ConsumerWidget {
  const ThemePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final choice = ref.watch(themeChoiceProvider);
    final n = ref.read(themeChoiceProvider.notifier);
    final custom = ColorTheme.custom(choice.custom ?? const Color(0xFF1DBEEF));
    return Scaffold(
      appBar: AppBar(title: const Text('主題')),
      body: GridView.extent(
        maxCrossAxisExtent: 260,
        padding: const EdgeInsets.all(16),
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.35,
        children: [
          for (final t in presets) ThemeCard(theme: t, selected: choice.id == t.id, onTap: () => n.choose(t.id)),
          ThemeCard(
            theme: custom,
            selected: choice.id == 'custom',
            edit: true,
            onTap: () async {
              final c = await pickThemeColor(context, choice.custom ?? const Color(0xFF1DBEEF));
              if (c != null) await n.choose('custom', custom: c);
            },
          ),
        ],
      ),
    );
  }
}

/// A theme's name over a small dark and light preview.
class ThemeCard extends StatelessWidget {
  const ThemeCard({super.key, required this.theme, required this.selected, required this.onTap, this.edit = false});
  final ColorTheme theme;
  final bool selected, edit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: selected ? cs.primary : Colors.transparent, width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(theme.name, style: const TextStyle(fontWeight: FontWeight.bold))),
              if (selected) Icon(Icons.check_circle, size: 18, color: cs.primary),
              if (edit) Icon(Icons.edit_outlined, size: 18, color: cs.onSurfaceVariant),
            ]),
            Text(theme.origin, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            const SizedBox(height: 8),
            Expanded(child: Row(children: [Expanded(child: _Preview(theme.dark)), const SizedBox(width: 6), Expanded(child: _Preview(theme.light))])),
          ]),
        ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview(this.p);
  final Palette p;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(color: p.bg, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.card)),
        child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(5)),
            child: Row(children: [
              Container(width: 12, height: 12, decoration: BoxDecoration(color: p.main, shape: BoxShape.circle)),
              const SizedBox(width: 4),
              Expanded(child: Container(height: 4, decoration: BoxDecoration(color: p.text, borderRadius: BorderRadius.circular(2)))),
            ]),
          ),
          Row(children: [
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(color: p.play, shape: BoxShape.circle),
              child: Icon(Icons.play_arrow, size: 12, color: p.onPlay),
            ),
            const SizedBox(width: 4),
            Expanded(child: Container(height: 3, decoration: BoxDecoration(color: p.main, borderRadius: BorderRadius.circular(2)))),
          ]),
        ]),
      );
}

/// 自訂: a colour from a row of swatches or the hue / saturation / lightness
/// sliders; the dark and light versions are shown as it changes.
Future<Color?> pickThemeColor(BuildContext context, Color start) => showDialog<Color>(
      context: context,
      builder: (ctx) => _ColorDialog(start),
    );

class _ColorDialog extends StatefulWidget {
  const _ColorDialog(this.start);
  final Color start;

  @override
  State<_ColorDialog> createState() => _ColorDialogState();
}

class _ColorDialogState extends State<_ColorDialog> {
  late HSLColor _c = HSLColor.fromColor(widget.start);

  static const _swatches = [
    0xFF1DBEEF, 0xFF3B82F6, 0xFF6366F1, 0xFF8B5CF6, 0xFFD946EF, 0xFFEC4899, 0xFFF43F5E, 0xFFEF4444, //
    0xFFF97316, 0xFFF59E0B, 0xFFEAB308, 0xFF84CC16, 0xFF22C55E, 0xFF10B981, 0xFF14B8A6, 0xFF06B6D4,
  ];

  @override
  Widget build(BuildContext context) {
    final color = _c.toColor();
    final t = ColorTheme.custom(color);
    Widget slider(String label, double value, double max, ValueChanged<double> on) => Row(children: [
          SizedBox(width: 48, child: Text(label)),
          Expanded(child: Slider(value: value, max: max, onChanged: (v) => setState(() => on(v)))),
        ]);
    return AlertDialog(
      title: const Text('自訂主題'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final s in _swatches)
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => setState(() => _c = HSLColor.fromColor(Color(s))),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: Color(s),
                      shape: BoxShape.circle,
                      border: Border.all(color: color.toARGB32() == s ? Theme.of(context).colorScheme.onSurface : Colors.transparent, width: 2),
                    ),
                  ),
                ),
            ]),
            const SizedBox(height: 12),
            slider('色相', _c.hue, 360, (v) => _c = _c.withHue(v)),
            slider('飽和', _c.saturation, 1, (v) => _c = _c.withSaturation(v)),
            slider('明暗', _c.lightness, 1, (v) => _c = _c.withLightness(v.clamp(0.15, 0.85))),
            const SizedBox(height: 8),
            SizedBox(height: 90, child: Row(children: [Expanded(child: _Preview(t.dark)), const SizedBox(width: 8), Expanded(child: _Preview(t.light))])),
            const SizedBox(height: 6),
            Text('#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, color), child: const Text('使用')),
      ],
    );
  }
}
