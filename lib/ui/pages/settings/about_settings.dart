import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';
import '../../../services/app_icon.dart';
import '../../../services/updater.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/update_dialog.dart';
import 'section_page.dart';

/// 關於與更新: the version, the app icon and in-app updates (Android).
class AboutSettingsPage extends ConsumerStatefulWidget {
  const AboutSettingsPage({super.key});

  @override
  ConsumerState<AboutSettingsPage> createState() => _AboutSettingsPageState();
}

const _dark = 'assets/icon/app_icon_dark.png';
const _lightAsset = 'assets/icon/app_icon_light.png';

class _AboutSettingsPageState extends ConsumerState<AboutSettingsPage> {
  bool _checking = false;
  bool? _light;

  @override
  void initState() {
    super.initState();
    if (AppIcon.supported) {
      AppIcon.isLight().then((v) {
        if (mounted) setState(() => _light = v);
      }).catchError((_) {});
    }
  }

  Future<void> _setIcon(bool light) async {
    if (light == _light && !ref.read(settingsProvider).iconFollowTheme) return;
    if (light == _light) {
      ref.read(settingsProvider.notifier).setIconFollowTheme(false);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        title: Text('換成${light ? '淺色' : '深色'}圖示？'),
        content: const Text('桌面上的圖示會在幾秒內換成新的。\n\n'
            '有些桌面會把舊圖示移除，這時從 App 清單把 OuOPlayer 重新拖到桌面就好。少數手機會關閉 App 一次，重新打開即可。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('更換')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      ref.read(settingsProvider.notifier).setIconFollowTheme(false);
      await AppIcon.setLight(light);
      if (!mounted) return;
      setState(() => _light = light);
      toast(context, '已換成${light ? '淺色' : '深色'}圖示');
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  Future<void> _follow() async {
    if (ref.read(settingsProvider).iconFollowTheme) return;
    final ok = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        title: const Text('圖示跟隨主題？'),
        content: const Text('深色主題用深色圖示，淺色主題用淺色圖示（跟隨系統時看手機的深淺色）。\n\n'
            '主題改變後，圖示會在你離開 OuOPlayer 時才換，避免使用中被打斷。'
            '有些桌面換圖示時會把桌面上的圖示移除，這時從 App 清單重新拖到桌面就好。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('跟隨主題')),
        ],
      ),
    );
    if (ok != true) return;
    ref.read(settingsProvider.notifier).setIconFollowTheme(true);
    if (mounted) toast(context, '離開 OuOPlayer 後，圖示會換成跟主題相同的顏色');
  }

  Widget _iconChoice(String label, Widget image, {required bool selected, required VoidCallback? onTap}) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? cs.primary : cs.outlineVariant, width: selected ? 2 : 1),
        ),
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
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return SettingsSectionPage(title: '關於與更新', children: [
      const ListTile(leading: Icon(Icons.info_outline), title: Text('OuOPlayer'), subtitle: Text('版本 1.0.0')),
      if (AppIcon.supported) ...[
        const ListTile(leading: Icon(Icons.palette_outlined), title: Text('App 圖示'), subtitle: Text('桌面和 App 清單上的圖示')),
        Padding(
          padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
          child: Wrap(spacing: 10, runSpacing: 10, children: [
            _iconChoice('深色', Image.asset(_dark),
                selected: !s.iconFollowTheme && _light == false, onTap: _light == null ? null : () => _setIcon(false)),
            _iconChoice('淺色', Image.asset(_lightAsset),
                selected: !s.iconFollowTheme && _light == true, onTap: _light == null ? null : () => _setIcon(true)),
            // Half dark, half light.
            _iconChoice(
                '跟隨主題',
                Row(children: [
                  Expanded(child: ClipRect(child: Align(alignment: Alignment.centerLeft, widthFactor: 0.5, child: Image.asset(_dark)))),
                  Expanded(child: ClipRect(child: Align(alignment: Alignment.centerRight, widthFactor: 0.5, child: Image.asset(_lightAsset)))),
                ]),
                selected: s.iconFollowTheme,
                onTap: _follow),
          ]),
        ),
      ],
      if (Updater.supported) ...[
        ListTile(
          leading: _checking
              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.system_update_outlined),
          title: const Text('檢查更新'),
          onTap: _checking
              ? null
              : () async {
                  setState(() => _checking = true);
                  await checkForUpdate(context, ref, manual: true);
                  if (mounted) setState(() => _checking = false);
                },
        ),
        SwitchListTile(
          secondary: const Icon(Icons.update),
          title: const Text('自動檢查更新'),
          subtitle: const Text('每天第一次打開 App 時檢查；有新版本時會先問你'),
          value: s.autoUpdateCheck,
          onChanged: n.setAutoUpdateCheck,
        ),
      ],
    ]);
  }
}
