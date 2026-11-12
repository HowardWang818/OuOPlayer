import 'package:flutter/material.dart';

import '../../config/links.dart';
import '../widgets/links.dart';

/// 隱私說明: a short version of docs/PRIVACY.md (the full policy).
class PrivacyPage extends StatelessWidget {
  const PrivacyPage({super.key});

  static const sections = <(String, String)>[
    ('概要', '不需要帳號、無廣告，不收集個人資料。'),
    ('同步', '同步資料儲存在使用者的 Google 雲端硬碟，開發者無法存取。'),
    ('網路服務', '僅在使用相關功能時連線：LRCLIB、Apple iTunes、Deezer、mora、OTOTOY、YouTube、SoundCloud、Google 雲端硬碟。'),
    ('開源', 'OuOPlayer 以 GPL-3.0 授權開源。'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('隱私說明')),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
        for (final (title, body) in sections) ...[
          const SizedBox(height: 16),
          Text(title, style: t.titleMedium),
          const SizedBox(height: 6),
          Text(body, style: t.bodyMedium?.copyWith(height: 1.5)),
        ],
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => openExternal(context, privacyUrl),
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('完整隱私權政策'),
          ),
        ),
      ]),
    );
  }
}
