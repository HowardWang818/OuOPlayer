import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config/lastfm_config.dart';
import '../../../providers/providers.dart';
import '../../../services/scrobble.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/links.dart';
import 'section_page.dart';

final scrobblerProvider = Provider<Scrobbler>((ref) => Scrobbler(ref.watch(dbProvider)));

/// Who is signed in to Last.fm / ListenBrainz (refreshed after changes).
final scrobbleAccountsProvider = FutureProvider<({String? lastFm, String? listenBrainz})>((ref) async {
  final s = await ref.watch(dbProvider).allSettings();
  String? name(String key) => (s[key] ?? '').isEmpty ? null : s[key];
  return (
    lastFm: (s[Scrobbler.lastFmSessionKey] ?? '').isEmpty ? null : name(Scrobbler.lastFmUserKey) ?? 'Last.fm',
    listenBrainz: (s[Scrobbler.listenBrainzKey] ?? '').isEmpty ? null : name(Scrobbler.listenBrainzUserKey) ?? 'ListenBrainz',
  );
});

/// 播放記錄 in 播放紀錄與統計: Last.fm and ListenBrainz accounts.
class ScrobbleSection extends ConsumerWidget {
  const ScrobbleSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(scrobbleAccountsProvider).value;
    final db = ref.read(dbProvider);
    void refresh() => ref.invalidate(scrobbleAccountsProvider);

    Future<void> signOut(String service, List<String> keys) async {
      if (!await confirmDelete(context, title: '停止記錄至 $service？', action: '停止')) {
        return;
      }
      for (final k in keys) {
        await db.setSetting(k, '');
      }
      refresh();
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      settingsSubheader(context, '播放記錄'),
      if (lastFmAvailable)
        SettingTile(
          action: accounts?.lastFm == null ? '登入' : '停止',
          leading: const Icon(Icons.radio_outlined),
          title: const Text('Last.fm'),
          subtitle: accounts?.lastFm == null ? null : Text('已登入：${accounts!.lastFm}'),
          onTap: () => accounts?.lastFm == null
              ? _lastFmSignIn(context, ref)
              : signOut('Last.fm', [Scrobbler.lastFmSessionKey, Scrobbler.lastFmUserKey, Scrobbler.queueKey('lastfm')]),
        ),
      SettingTile(
        action: accounts?.listenBrainz == null ? '設定' : '停止',
        leading: const Icon(Icons.hearing_outlined),
        title: const Text('ListenBrainz'),
        subtitle: accounts?.listenBrainz == null ? null : Text('已登入：${accounts!.listenBrainz}'),
        onTap: () => accounts?.listenBrainz == null
            ? _listenBrainzSignIn(context, ref)
            : signOut('ListenBrainz', [Scrobbler.listenBrainzKey, Scrobbler.listenBrainzUserKey, Scrobbler.queueKey('listenbrainz')]),
      ),
    ]);
  }

  Future<void> _lastFmSignIn(BuildContext context, WidgetRef ref) async {
    final String token;
    try {
      final (t, url) = await LastFm.startSignIn();
      token = t;
      if (context.mounted) await openExternal(context, url);
    } catch (e) {
      if (context.mounted) toast(context, '無法連線至 Last.fm');
      return;
    }
    if (!context.mounted) return;
    final done = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Last.fm'),
        content: const Text('在瀏覽器完成授權後點「完成」。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('完成')),
        ],
      ),
    );
    if (done != true) return;
    try {
      final (session, name) = await LastFm.finishSignIn(token);
      final db = ref.read(dbProvider);
      await db.setSetting(Scrobbler.lastFmSessionKey, session);
      await db.setSetting(Scrobbler.lastFmUserKey, name);
      ref.invalidate(scrobbleAccountsProvider);
      if (context.mounted) toast(context, '已登入 $name');
    } catch (e) {
      if (context.mounted) toast(context, '授權未完成，請再試一次');
    }
  }

  Future<void> _listenBrainzSignIn(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController();
    final token = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ListenBrainz 權杖'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextButton(onPressed: () => openExternal(ctx, 'https://listenbrainz.org/settings/'), child: const Text('打開設定頁')),
          TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: 'User token')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('確定')),
        ],
      ),
    );
    ctrl.dispose();
    if (token == null || token.isEmpty) return;
    try {
      final name = await ListenBrainz.check(token);
      if (name == null) {
        if (context.mounted) toast(context, '權杖無效');
        return;
      }
      final db = ref.read(dbProvider);
      await db.setSetting(Scrobbler.listenBrainzKey, token);
      await db.setSetting(Scrobbler.listenBrainzUserKey, name);
      ref.invalidate(scrobbleAccountsProvider);
      if (context.mounted) toast(context, '已登入 $name');
    } catch (e) {
      if (context.mounted) toast(context, '無法連線至 ListenBrainz');
    }
  }
}
