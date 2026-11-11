import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config/version.dart';
import '../../providers/providers.dart';
import 'privacy_page.dart';
import 'settings/library_settings.dart' show addMusicFolder;

/// A new install (set in main.dart): 第一次使用 shows instead of 這版新功能.
final firstRunProvider = Provider<bool>((ref) => false);

/// After start-up: the first-run guide on a new install; otherwise, the
/// first time a new version opens, what's new in it.
class FirstRunGate extends ConsumerStatefulWidget {
  const FirstRunGate({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<FirstRunGate> createState() => _FirstRunGateState();
}

class _FirstRunGateState extends ConsumerState<FirstRunGate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final db = ref.read(dbProvider);
    final m = await db.allSettings();
    if (!mounted) return;
    final first = ref.read(firstRunProvider);
    if (first) {
      await Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const OnboardingPage()));
    } else if (whatsNewDue(firstRun: first, seenVersion: m['seen_version'])) {
      await showWhatsNew(context);
    }
    await db.setSetting('onboarded', 'true');
    await db.setSetting('seen_version', appVersion);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 這版新功能 shows once per version, but not on a new install (the guide
/// shows then). Copies from before 1.18.0 never stored [seenVersion].
bool whatsNewDue({required bool firstRun, required String? seenVersion}) => !firstRun && seenVersion != appVersion;

/// The lines of assets/whats_new.txt (written for each version).
Future<List<String>> whatsNewLines() async {
  try {
    final text = await rootBundle.loadString('assets/whats_new.txt');
    return [for (final l in text.split('\n')) if (l.trim().isNotEmpty) l.trim()];
  } catch (_) {
    return const [];
  }
}

/// 這版新功能: a short list, the first time a new version opens.
Future<void> showWhatsNew(BuildContext context) async {
  final lines = await whatsNewLines();
  if (lines.isEmpty || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('$appVersion 新功能'),
      content: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(l.startsWith('•') ? l : '• $l', style: const TextStyle(height: 1.4)),
            ),
        ]),
      ),
      actions: [FilledButton(autofocus: true, onPressed: () => Navigator.pop(ctx), child: const Text('好'))],
    ),
  );
}

/// 第一次使用: two steps where friends got stuck: getting downloads ready
/// (the download parts and the YouTube key) and picking the music folder.
class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key});

  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  final _pages = PageController();
  int _step = 0;
  bool _preparing = false;
  String? _status;
  bool _ready = false;
  int _folders = 0;

  @override
  void initState() {
    super.initState();
    ref.read(downloadServiceProvider).ytdlp?.isReady().then((v) {
      if (mounted) setState(() => _ready = v);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    final backend = ref.read(downloadServiceProvider).ytdlp;
    if (backend == null) return;
    setState(() {
      _preparing = true;
      _status = '準備中…';
    });
    try {
      await backend.prepare((s) {
        if (mounted) setState(() => _status = s);
      });
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  void _next() {
    if (_step == 1) return Navigator.pop(context);
    _pages.nextPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
        body: SafeArea(
          child: Column(children: [
            Expanded(
              child: PageView(
                controller: _pages,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (i) => setState(() => _step = i),
                children: [_downloads(context), _folder(context)],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(children: [
                for (var i = 0; i < 2; i++)
                  Container(
                    width: i == _step ? 20 : 8,
                    height: 8,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(color: i == _step ? cs.primary : cs.outlineVariant, borderRadius: BorderRadius.circular(4)),
                  ),
                const Spacer(),
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('略過')),
                const SizedBox(width: 8),
                FilledButton(onPressed: _next, child: Text(_step == 1 ? '開始使用' : '下一步')),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: InkWell(
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PrivacyPage())),
                  child: Text('隱私說明', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12, decoration: TextDecoration.underline)),
                ),
              ),
            ),
          ]),
        ),
    );
  }

  Widget _frame(BuildContext context, {required IconData icon, required String title, required String text, required List<Widget> children}) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.fromLTRB(24, 32, 24, 16), children: [
      Icon(icon, size: 48, color: cs.primary),
      const SizedBox(height: 16),
      Text(title, style: t.headlineSmall),
      const SizedBox(height: 8),
      Text(text, style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant, height: 1.5)),
      const SizedBox(height: 24),
      ...children,
    ]);
  }

  Widget _downloads(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final backend = ref.read(downloadServiceProvider).ytdlp;
    return _frame(
      context,
      icon: Icons.download_for_offline_outlined,
      title: '歡迎使用 OuOPlayer',
      text: '本機音樂播放器，手機與電腦同步。免費、開源、無廣告。',
      children: [
        if (backend != null)
          Card(
            child: ListTile(
              leading: _preparing
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(_ready ? Icons.check_circle : Icons.extension_outlined, color: _ready ? Colors.green : null),
              title: Text(Platform.isAndroid ? '下載元件（約 50 MB）' : '下載元件'),
              subtitle: _ready ? const Text('已就緒') : (_status == null ? null : Text(_status!)),
              trailing: _ready || _preparing ? null : FilledButton.tonal(onPressed: _prepare, child: const Text('下載')),
            ),
          ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('下載位置'),
            subtitle: Text(s.downloadDir, style: TextStyle(color: muted)),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () async {
              final dir = await FilePicker.getDirectoryPath(dialogTitle: '選擇下載位置');
              if (dir != null) n.setDownloadDir(dir);
            },
          ),
        ),
      ],
    );
  }

  Widget _folder(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return _frame(
      context,
      icon: Icons.library_music_outlined,
      title: '音樂資料夾',
      text: '選擇要加入音樂庫的資料夾。',
      children: [
        for (final d in s.musicDirs)
          ListTile(dense: true, leading: const Icon(Icons.folder_outlined), title: Text(d, style: TextStyle(color: muted))),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: () async {
            if (await addMusicFolder(context, ref, scan: true) && mounted) setState(() => _folders++);
          },
          icon: const Icon(Icons.create_new_folder_outlined),
          label: Text(_folders == 0 ? '選擇資料夾' : '新增資料夾'),
        ),
      ],
    );
  }
}
