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
      if (!await confirmDelete(context, title: '停止記錄到 $service？', message: '這台不再把播放記錄傳到 $service，還沒傳出的也會清掉。$service 上已經有的紀錄不受影響。', action: '停止')) {
        return;
      }
      for (final k in keys) {
        await db.setSetting(k, '');
      }
      refresh();
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      settingsSubheader(context, '播放記錄（Last.fm／ListenBrainz）'),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text('聽超過一半（或 4 分鐘）的歌，會記到你的帳號；沒網路時先存著，之後補傳。Podcast 不會記。',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
      ),
      if (lastFmAvailable)
        SettingTile(
          action: accounts?.lastFm == null ? '登入' : '停止',
          leading: const Icon(Icons.radio_outlined),
          title: const Text('Last.fm'),
          subtitle: Text(accounts?.lastFm == null ? '用瀏覽器登入 Last.fm 授權，OuOPlayer 不會看到你的密碼' : '已登入：${accounts!.lastFm}'),
          onTap: () => accounts?.lastFm == null
              ? _lastFmSignIn(context, ref)
              : signOut('Last.fm', [Scrobbler.lastFmSessionKey, Scrobbler.lastFmUserKey, Scrobbler.queueKey('lastfm')]),
        ),
      SettingTile(
        action: accounts?.listenBrainz == null ? '設定' : '停止',
        leading: const Icon(Icons.hearing_outlined),
        title: const Text('ListenBrainz'),
        subtitle: Text(accounts?.listenBrainz == null ? '貼上 listenbrainz.org 設定頁的使用者權杖' : '已登入：${accounts!.listenBrainz}'),
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
      if (context.mounted) toast(context, '無法連到 Last.fm：$e');
      return;
    }
    if (!context.mounted) return;
    final done = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('在瀏覽器允許 OuOPlayer'),
        content: const Text('瀏覽器已打開 Last.fm。登入後按「Yes, allow access」，再回來按「我已允許」。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('我已允許')),
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
      if (context.mounted) toast(context, '已登入 Last.fm：$name');
    } catch (e) {
      if (context.mounted) toast(context, '還沒有授權成功，請再試一次（$e）');
    }
  }

  Future<void> _listenBrainzSignIn(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController();
    final token = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ListenBrainz 權杖'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('登入 listenbrainz.org，到「Settings」複製「User token」貼在這裡。'),
          TextButton(onPressed: () => openExternal(ctx, 'https://listenbrainz.org/settings/'), child: const Text('打開設定頁')),
          TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: '使用者權杖')),
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
        if (context.mounted) toast(context, '這個權杖無效，請再確認一次');
        return;
      }
      final db = ref.read(dbProvider);
      await db.setSetting(Scrobbler.listenBrainzKey, token);
      await db.setSetting(Scrobbler.listenBrainzUserKey, name);
      ref.invalidate(scrobbleAccountsProvider);
      if (context.mounted) toast(context, '已連上 ListenBrainz：$name');
    } catch (e) {
      if (context.mounted) toast(context, '無法連到 ListenBrainz：$e');
    }
  }
}
