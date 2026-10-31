import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shell/app_shortcuts.dart';
import '../../widgets/dialogs.dart';
import 'section_page.dart';

/// Windows: the row in 設定 that opens the list of keys.
class ShortcutSettingsEntry extends StatelessWidget {
  const ShortcutSettingsEntry({super.key});

  @override
  Widget build(BuildContext context) => SettingsSectionPage(title: '快捷鍵', children: [
        SettingTile(
          leading: const Icon(Icons.keyboard_outlined),
          title: const Text('自訂快捷鍵'),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ShortcutSettingsPage())),
        ),
      ]);
}

class ShortcutSettingsPage extends ConsumerWidget {
  const ShortcutSettingsPage({super.key});

  Future<void> _change(BuildContext context, WidgetRef ref, AppAction action) async {
    final picked = await showDialog<({KeyCombo? combo})>(
      context: context,
      useRootNavigator: true,
      builder: (_) => KeyCapture(action: action),
    );
    if (picked == null || !context.mounted) return;
    final combo = picked.combo;
    final keys = ref.read(shortcutsProvider);
    final other = combo == null ? null : actionFor(keys, combo);
    if (other != null && other != action) {
      final ok = await confirmDelete(context,
          title: '「${combo!.label}」已用在「${other.label}」', message: '要改給「${action.label}」嗎？「${other.label}」會變成未指定。', action: '改用');
      if (!ok) return;
    }
    ref.read(shortcutsProvider.notifier).set(action, combo);
  }

  Future<void> _reset(BuildContext context, WidgetRef ref) async {
    if (!await confirmDelete(context, title: '還原預設快捷鍵？', message: '自訂的按鍵都會改回預設。', action: '還原')) return;
    ref.read(shortcutsProvider.notifier).reset();
    if (context.mounted) toast(context, '已還原預設快捷鍵');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keys = ref.watch(shortcutsProvider);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return SettingsSectionPage(title: '快捷鍵', children: [
      for (final a in AppAction.values)
        SettingTile(
          title: Text(a.label),
          trailing: Text(keys[a]?.label ?? '未指定', style: TextStyle(color: muted)),
          action: '變更',
          onTap: () => _change(context, ref, a),
        ),
      SettingTile(
        leading: const Icon(Icons.restart_alt),
        title: const Text('還原預設'),
        action: '還原',
        onTap: () => _reset(context, ref),
      ),
    ]);
  }
}

/// Shows the key pressed until 儲存. While open, every key comes here and
/// does nothing else; Esc means 未指定. Pops with the choice, or with nothing
/// when cancelled.
class KeyCapture extends StatefulWidget {
  const KeyCapture({super.key, required this.action});
  final AppAction action;

  @override
  State<KeyCapture> createState() => _KeyCaptureState();
}

class _KeyCaptureState extends State<KeyCapture> {
  ({KeyCombo? combo})? _picked;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_onKey);
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_onKey);
    super.dispose();
  }

  // Ahead of the focus tree, or Esc would also close this dialog.
  KeyEventResult _onKey(KeyEvent e) {
    if (e is KeyDownEvent) {
      final combo = KeyCombo.ofEvent(e);
      if (combo.isEscape) {
        setState(() => _picked = (combo: null));
      } else if (keyNames.containsKey(combo.key)) {
        setState(() => _picked = (combo: combo));
      }
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final picked = _picked;
    return AlertDialog(
      title: Text('變更「${widget.action.label}」'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('請按下新的按鍵，可以搭配 Ctrl、Shift、Alt。\n按 Esc 設為未指定。'),
        const SizedBox(height: 16),
        Text(picked == null ? '等待按鍵…' : picked.combo?.label ?? '未指定', style: Theme.of(context).textTheme.titleLarge),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: picked == null ? null : () => Navigator.pop(context, picked), child: const Text('儲存')),
      ],
    );
  }
}

/// The keys in use (快捷鍵一覽).
Future<void> showShortcutHelp(BuildContext context, Map<AppAction, KeyCombo?> keys) => showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        title: const Text('快捷鍵一覽'),
        content: SizedBox(
          width: 360,
          child: ListView(shrinkWrap: true, children: [
            for (final a in AppAction.values)
              if (keys[a] != null)
                ListTile(dense: true, title: Text(a.label), trailing: Text(keys[a]!.label)),
            const ListTile(dense: true, title: Text('返回'), trailing: Text('Esc')),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('關閉'))],
      ),
    );
