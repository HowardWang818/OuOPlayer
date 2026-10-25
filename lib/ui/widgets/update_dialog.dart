import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../../services/network_check.dart';
import '../../services/updater.dart';
import 'dialogs.dart';

/// Checks for a new version. [manual] (關於與更新 →「檢查更新」) also says
/// when there is none or the check failed; the automatic one stays quiet.
Future<void> checkForUpdate(BuildContext context, WidgetRef ref, {bool manual = false}) async {
  if (!Updater.supported) return;
  try {
    final info = await Updater().latest();
    final me = await Updater.current();
    await ref.read(dbProvider).setSetting('update_last_check', DateTime.now().toIso8601String());
    if (!context.mounted) return;
    if (!info.isNewerThan(me.build)) {
      if (manual) toast(context, '已是最新版本（${me.name}）');
      return;
    }
    await _offer(context, info, me.name);
  } catch (e) {
    if (manual && context.mounted) toast(context, Updater.explain(e));
  }
}

Future<void> _offer(BuildContext context, UpdateInfo info, String mine) async {
  final go = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => AlertDialog(
      title: Text('有新版本 ${info.version}'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('目前版本：$mine', style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
          if (info.notes.isNotEmpty) ...[const SizedBox(height: 12), Text(info.notes)],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('之後再說')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('更新')),
      ],
    ),
  );
  if (go == true && context.mounted) await _downloadAndInstall(context, info);
}

Future<void> _downloadAndInstall(BuildContext context, UpdateInfo info) async {
  if (!await Updater.canInstall()) {
    if (!context.mounted) return;
    final open = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        title: const Text('允許 OuOPlayer 安裝更新'),
        content: const Text('Android 需要你允許 OuOPlayer「安裝不明應用程式」，才能裝上新版本。\n\n打開設定後開啟「允許這個來源」，再回來按一次「更新」。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('打開設定')),
        ],
      ),
    );
    if (open == true) await Updater.openInstallSettings();
    return;
  }
  if (!context.mounted) return;
  final abis = await Updater.abis();
  final size = info.apkFor(abis)?.size ?? 0;
  if (!context.mounted ||
      !await okToDownload(context,
          warn: ProviderScope.containerOf(context).read(settingsProvider).wifiWarning,
          size: size > 0 ? '約 ${(size / 1048576).round()} MB' : null)) {
    return;
  }
  if (!context.mounted) return;
  final progress = ValueNotifier<double?>(null);
  final cancel = CancelToken();
  final nav = Navigator.of(context, rootNavigator: true);
  showDialog(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text('下載 ${info.version}'),
        content: ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (_, v, __) => Column(mainAxisSize: MainAxisSize.min, children: [
            LinearProgressIndicator(value: v),
            const SizedBox(height: 8),
            Text(v == null ? '連線中…' : '${(v * 100).round()}%'),
          ]),
        ),
        actions: [TextButton(onPressed: () => cancel.cancel(), child: const Text('取消'))],
      ),
    ),
  );
  try {
    final apk = await Updater().download(info, cancel: cancel, onProgress: (got, total) {
      if (total > 0) progress.value = got / total;
    });
    nav.pop();
    await Updater.install(apk);
  } catch (e) {
    nav.pop();
    if (context.mounted) toast(context, e is DioException && CancelToken.isCancel(e) ? '已取消更新' : Updater.explain(e));
  } finally {
    progress.dispose();
  }
}

/// Checks once a day, a little after start-up, when 自動檢查更新 is on.
class UpdateWatcher extends ConsumerStatefulWidget {
  const UpdateWatcher({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<UpdateWatcher> createState() => _UpdateWatcherState();
}

class _UpdateWatcherState extends ConsumerState<UpdateWatcher> {
  @override
  void initState() {
    super.initState();
    if (!Updater.supported) return;
    Future.delayed(const Duration(seconds: 8), () async {
      if (!mounted || !ref.read(settingsProvider).autoUpdateCheck) return;
      final last = DateTime.tryParse((await ref.read(dbProvider).allSettings())['update_last_check'] ?? '');
      if (last != null && DateTime.now().difference(last) < const Duration(hours: 20)) return;
      if (mounted) await checkForUpdate(context, ref);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
