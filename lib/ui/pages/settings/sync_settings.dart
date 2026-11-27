import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';
import '../../../providers/sync_provider.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/power_tile.dart';
import 'section_page.dart';
import 'sync_log_page.dart';

/// 同步: Google sign-in, which playlists sync, the relay limit. Songs on
/// their way show only in the notification (phone) / taskbar (Windows).
class SyncSettingsPage extends ConsumerStatefulWidget {
  const SyncSettingsPage({super.key});

  @override
  ConsumerState<SyncSettingsPage> createState() => _SyncSettingsPageState();
}

class _SyncSettingsPageState extends ConsumerState<SyncSettingsPage> {
  Set<int> _synced = {};
  bool _liked = false;
  double _gb = 5;
  Map<String, String> _s = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final engine = ref.read(syncEngineProvider);
    final synced = await engine.syncedPlaylists();
    final liked = await engine.likedSynced;
    final s = await ref.read(dbProvider).allSettings();
    final gb = double.tryParse(s['sync_relay_gb'] ?? '') ?? 5;
    if (mounted) {
      setState(() {
        _s = s;
        _synced = synced;
        _liked = liked;
        _gb = gb;
      });
    }
  }

  String _when(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '剛剛';
    if (d.inHours < 1) return '${d.inMinutes} 分鐘前';
    if (d.inDays < 1) return '${d.inHours} 小時前';
    return '${t.month}/${t.day} ${t.hour}:${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(syncProvider);
    final n = ref.read(syncProvider.notifier);
    final engine = ref.read(syncEngineProvider);
    final playlists = ref.watch(playlistsProvider).value ?? const [];
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return SettingsSectionPage(title: '同步', children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Text(
            '勾選的播放清單會透過你自己的 Google 雲端硬碟，在手機和電腦之間保持一致：加歌、移除、排序、改名、刪除都會同步。'
            '另一台缺的歌會先暫存到雲端硬碟，另一台下載完就刪掉，不用兩台同時開著。沒勾選的清單和其他歌曲不會上傳。',
            style: TextStyle(color: muted, height: 1.5)),
      ),
      if (!sync.signedIn)
        SettingTile(
          action: '登入',
          leading: const Icon(Icons.login),
          title: const Text('用 Google 登入'),
          subtitle: Text(Platform.isAndroid ? '選擇帳號並允許 OuOPlayer 使用雲端硬碟的專用資料夾' : '會打開瀏覽器登入，完成後回到這裡'),
          onTap: () => n.signIn(context),
        )
      else ...[
        ListTile(
          leading: const Icon(Icons.account_circle_outlined),
          title: Text(sync.email?.isNotEmpty == true ? sync.email! : '已登入 Google'),
          subtitle: Text(sync.last == null ? '還沒同步過' : '上次同步：${_when(sync.last!)}${sync.message == null ? '' : '（${sync.message}）'}'),
          // Beside the account, where it is looked for (it was at the very bottom).
          trailing: OutlinedButton.icon(
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('登出'),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('登出 Google？'),
                  content: const Text('這台之後不會再同步，已經在這台的播放清單都會保留，雲端資料也不會被刪除。'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('登出')),
                  ],
                ),
              );
              if (ok == true) {
                await n.signOut();
                if (context.mounted) toast(context, '已登出 Google');
              }
            },
          ),
        ),
        SettingTile(
          action: '更改',
          leading: const Icon(Icons.edit_outlined),
          title: const Text('裝置名稱'),
          subtitle: FutureBuilder<String>(
            future: deviceNameOf(ref.read(dbProvider)),
            builder: (_, snap) => Text(snap.data ?? '', style: TextStyle(color: muted)),
          ),
          onTap: () async {
            final db = ref.read(dbProvider);
            final now = await deviceNameOf(db);
            if (!context.mounted) return;
            final name = await promptText(context, title: '裝置名稱', initial: now);
            if (name == null) return;
            await db.setSetting(deviceNameKey, name);
            engine.deviceName = await deviceNameOf(db);
            await _load();
            await n.run();
          },
        ),
        SettingTile(
          action: '同步',
          leading: sync.running ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.sync),
          title: Text(sync.running ? '同步中…' : '立即同步'),
          enabled: !sync.running,
          onTap: n.run,
        ),
        if (Platform.isAndroid) const PowerTile(),
        settingsSubheader(context, '同步的播放清單'),
        SettingCheck(
          secondary: const Icon(Icons.favorite),
          title: const Text('已按讚的歌曲'),
          value: _liked,
          onChanged: (v) async {
            await engine.setLikedSynced(v == true);
            await _load();
            await n.run();
          },
        ),
        for (final pl in playlists)
          SettingCheck(
            secondary: const Icon(Icons.queue_music),
            title: Text(pl.name),
            value: _synced.contains(pl.id),
            onChanged: (v) async {
              v == true ? await engine.enable(pl.id) : await engine.disable(pl.id);
              await _load();
              await n.run();
            },
          ),
        settingsSubheader(context, '其他同步'),
        for (final (key, title, sub) in const [
          ('sync_edits', '歌曲資料', '同步清單裡的歌：歌名、歌手、專輯、封面、歌詞的修改，另一台同一首歌也跟著改'),
          ('sync_plays', '收聽紀錄', '播放次數、最近播放、收聽統計與年度回顧算兩台加起來（只傳歌名和時間，不傳檔案）'),
          ('sync_theme', '外觀主題', '設定 → 外觀 選的顏色主題（含自訂顏色）：在一台換了，另一台同步後也跟著換；深色／淺色各自設定'),
        ])
          SettingSwitch(
            title: Text(title),
            subtitle: Text(sub),
            value: _s[key] != 'false',
            onChanged: (v) async {
              await ref.read(dbProvider).setSetting(key, '$v');
              await _load();
              if (v) await n.run();
            },
          ),
        if (_s['sync_plays'] != 'false' && !ref.watch(settingsProvider).recordPlays)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('這台沒有在記錄播放（設定 → 播放紀錄與統計 → 記錄播放紀錄），新的播放不會同步。', style: TextStyle(color: muted, fontSize: 13)),
          ),
        settingsSubheader(context, '雲端中繼站'),
        ListTile(
          leading: const Icon(Icons.cloud_outlined),
          title: Text('暫存上限：${_gb.round()} GB'),
          subtitle: Slider(
            min: 1,
            max: 100,
            divisions: 99,
            value: _gb.clamp(1, 100),
            label: '${_gb.round()} GB',
            onChanged: (v) => setState(() => _gb = v),
            onChangeEnd: (v) => ref.read(dbProvider).setSetting('sync_relay_gb', '${v.round()}'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('還沒被另一台下載的歌最多佔用這麼多雲端空間；滿了就等另一台下載後再繼續傳。手機只在 Wi-Fi 下傳歌。',
              style: TextStyle(color: muted, fontSize: 13)),
        ),
      ],
      SettingTile(
        action: '查看',
        leading: const Icon(Icons.receipt_long_outlined),
        title: const Text('同步紀錄'),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SyncLogPage())),
      ),
    ]);
  }
}

