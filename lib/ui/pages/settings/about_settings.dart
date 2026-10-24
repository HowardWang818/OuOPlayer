import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';
import '../../../services/updater.dart';
import '../../widgets/update_dialog.dart';
import 'section_page.dart';

/// 關於與更新: the version, and in-app updates (Android).
class AboutSettingsPage extends ConsumerStatefulWidget {
  const AboutSettingsPage({super.key});

  @override
  ConsumerState<AboutSettingsPage> createState() => _AboutSettingsPageState();
}

class _AboutSettingsPageState extends ConsumerState<AboutSettingsPage> {
  bool _checking = false;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return SettingsSectionPage(title: '關於與更新', children: [
      const ListTile(leading: Icon(Icons.info_outline), title: Text('OuOPlayer'), subtitle: Text('版本 0.18.1')),
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
