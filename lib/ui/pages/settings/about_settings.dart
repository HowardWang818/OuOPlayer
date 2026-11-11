import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config/links.dart';
import '../../../config/update_config.dart';
import '../../../config/version.dart';
import '../../../providers/providers.dart';
import '../../../services/bug_report.dart';
import '../../../services/updater.dart';
import '../../widgets/links.dart';
import '../../widgets/update_dialog.dart';
import '../onboarding_page.dart' show showWhatsNew;
import '../privacy_page.dart';
import 'app_icon_setting.dart' show appIconDark;
import 'section_page.dart';

/// 關於與更新: the version, OuOPlayer's pages (GitHub, 回報問題, 隱私說明)
/// and in-app updates.
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
      ListTile(
        leading: ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.asset(appIconDark, width: 40, height: 40)),
        title: const Text('OuOPlayer'),
        subtitle: const Text('版本 $appVersion'),
      ),
      SettingTile(
        action: '開啟',
        leading: const Icon(Icons.code),
        title: const Text('GitHub'),
        onTap: () => openExternal(context, repoUrl),
      ),
      SettingTile(
        action: '回報',
        leading: const Icon(Icons.bug_report_outlined),
        title: const Text('回報問題'),
        onTap: () async {
          final url = await BugReport.newIssueUrl();
          if (context.mounted) await openExternal(context, url);
        },
      ),
      SettingTile(
        action: '查看',
        leading: const Icon(Icons.new_releases_outlined),
        title: const Text('這版新功能'),
        onTap: () => showWhatsNew(context),
      ),
      SettingTile(
        action: '開啟',
        leading: const Icon(Icons.history),
        title: const Text('更新紀錄'),
        onTap: () => openExternal(context, releasesPage),
      ),
      SettingTile(
        action: '查看',
        leading: const Icon(Icons.privacy_tip_outlined),
        title: const Text('隱私說明'),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PrivacyPage())),
      ),
      if (Updater.supported) ...[
        SettingTile(
          action: '檢查',
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
        SettingSwitch(
          secondary: const Icon(Icons.update),
          title: const Text('自動檢查更新'),
          value: s.autoUpdateCheck,
          onChanged: n.setAutoUpdateCheck,
        ),
      ],
    ]);
  }
}
