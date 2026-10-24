import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';
import '../devices_page.dart';
import 'section_page.dart';

/// 藍牙與車用 (Android only): headphones and Android Auto.
class DevicesSettingsPage extends ConsumerWidget {
  const DevicesSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return SettingsSectionPage(title: '藍牙與車用', children: [
      SwitchListTile(
        secondary: const Icon(Icons.bluetooth_audio),
        title: const Text('藍牙耳機連線時自動播放'),
        subtitle: const Text('接續上次的播放佇列；斷線時一律自動暫停'),
        value: s.btAutoPlay,
        onChanged: n.setBtAutoPlay,
      ),
      ListTile(
        leading: const Icon(Icons.devices),
        title: const Text('藍牙裝置'),
        subtitle: const Text('掃描、配對與連接'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => const DevicesPage())),
      ),
      ListTile(
        leading: const Icon(Icons.directions_car_outlined),
        title: const Text('Android Auto'),
        subtitle: const Text('在車上瀏覽播放清單、專輯、Podcast'),
        trailing: const Icon(Icons.help_outline),
        onTap: () => showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('在 Android Auto 使用 OuOPlayer'),
            content: const Text('Android Auto 預設只顯示從 Play 商店安裝的 App，所以要先開啟「不明來源」：\n\n'
                '1. 打開手機的 Android Auto 設定（設定 → 已連結的裝置 → Android Auto，或在設定裡搜尋「Android Auto」）。\n'
                '2. 往下找到「版本」，連續點擊約 10 次，出現提示後允許開啟開發人員設定。\n'
                '3. 右上角「⋮」→「開發人員設定」→ 勾選「不明來源」。\n'
                '4. 重新連接車子，OuOPlayer 就會出現在車上的媒體 App 裡。'),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('好'))],
          ),
        ),
      ),
    ]);
  }
}
