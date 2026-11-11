import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';
import '../../../services/app_icon.dart';
import '../../../theme/looks.dart';
import '../../widgets/dialogs.dart';

const appIconDark = 'assets/icon/app_icon_dark.png';
const appIconLight = 'assets/icon/app_icon_light.png';

/// App 圖示 in 外觀 (Android): dark, light, or following the theme.
class AppIconSetting extends ConsumerStatefulWidget {
  const AppIconSetting({super.key});

  @override
  ConsumerState<AppIconSetting> createState() => _AppIconSettingState();
}

class _AppIconSettingState extends ConsumerState<AppIconSetting> {
  bool? _light;

  @override
  void initState() {
    super.initState();
    AppIcon.isLight().then((v) {
      if (mounted) setState(() => _light = v);
    }).catchError((_) {});
  }

  Future<bool> _confirm(String title, String action) async =>
      await showDialog<bool>(
        context: context,
        useRootNavigator: true,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: const Text('桌面圖示若消失，請從 App 清單重新加入。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
          ],
        ),
      ) ==
      true;

  Future<void> _setIcon(bool light) async {
    final n = ref.read(settingsProvider.notifier);
    if (light == _light) {
      n.setIconFollowTheme(false);
      return;
    }
    if (!await _confirm('更換為${light ? '淺色' : '深色'}圖示？', '更換')) return;
    try {
      n.setIconFollowTheme(false);
      await AppIcon.setLight(light);
      if (mounted) setState(() => _light = light);
    } catch (e) {
      if (mounted) toast(context, '無法更換圖示');
    }
  }

  Future<void> _follow() async {
    if (ref.read(settingsProvider).iconFollowTheme) return;
    if (!await _confirm('圖示跟隨主題？', '跟隨主題')) return;
    ref.read(settingsProvider.notifier).setIconFollowTheme(true);
  }

  Widget _choice(String label, Widget image, {required bool selected, required VoidCallback? onTap}) {
    final cs = Theme.of(context).colorScheme;
    final r = BorderRadius.circular(Looks.of(context).radius(12));
    return InkWell(
      borderRadius: r,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(borderRadius: r, border: Border.all(color: selected ? cs.primary : cs.outlineVariant, width: selected ? 2 : 1)),
        child: Column(children: [
          ClipOval(child: SizedBox(width: 56, height: 56, child: image)),
          const SizedBox(height: 6),
          Row(mainAxisSize: MainAxisSize.min, children: [
            if (selected) Icon(Icons.check, size: 16, color: cs.primary),
            Text(label),
          ]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final follow = ref.watch(settingsProvider.select((s) => s.iconFollowTheme));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const ListTile(leading: Icon(Icons.apps_outlined), title: Text('App 圖示')),
      Padding(
        padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
        child: Wrap(spacing: 10, runSpacing: 10, children: [
          _choice('深色', Image.asset(appIconDark), selected: !follow && _light == false, onTap: _light == null ? null : () => _setIcon(false)),
          _choice('淺色', Image.asset(appIconLight), selected: !follow && _light == true, onTap: _light == null ? null : () => _setIcon(true)),
          // Half dark, half light.
          _choice(
              '跟隨主題',
              Row(children: [
                Expanded(child: ClipRect(child: Align(alignment: Alignment.centerLeft, widthFactor: 0.5, child: Image.asset(appIconDark)))),
                Expanded(child: ClipRect(child: Align(alignment: Alignment.centerRight, widthFactor: 0.5, child: Image.asset(appIconLight)))),
              ]),
              selected: follow,
              onTap: _follow),
        ]),
      ),
    ]);
  }
}
