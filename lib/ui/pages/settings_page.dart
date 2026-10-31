import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../providers/providers.dart';
import '../widgets/dialogs.dart';
import '../widgets/hover.dart';
import '../widgets/missing_files_dialog.dart';
import 'backup_page.dart';
import '../../config/version.dart';
import '../../services/updater.dart';
import 'settings/about_settings.dart';
import 'settings/devices_settings.dart';
import 'settings/download_settings.dart';
import 'settings/history_settings.dart';
import 'settings/library_settings.dart';
import 'settings/lyrics_settings.dart';
import 'settings/playback_settings.dart';
import 'settings/playlist_settings.dart';
import 'settings/podcast_settings.dart';
import 'settings/section_page.dart';
import 'settings/shortcut_settings.dart';
import 'storage_page.dart';
import '../../providers/sync_provider.dart' show syncAvailable;
import 'settings/sync_settings.dart';

Future<bool> ensureStoragePermission() async {
  if (!Platform.isAndroid) return true;
  final audio = await Permission.audio.request();
  if (audio.isGranted) return true;
  // Android 12 and lower use the legacy storage permission.
  final storage = await Permission.storage.request();
  return storage.isGranted;
}

Future<void> rescanLibrary(BuildContext context, WidgetRef ref) async {
  if (!await ensureStoragePermission()) {
    if (context.mounted) toast(context, '需要音樂檔案存取權限才能掃描');
    return;
  }
  final s = ref.read(settingsProvider);
  final dirs = {...s.musicDirs, s.downloadDir}.toList();
  final added = await ref.read(scannerProvider).scan(dirs);
  if (!context.mounted) return;
  toast(context, '掃描完成，新增 $added 首歌曲');
  await checkMissingFiles(context, ref);
}

/// The categories of 設定 (the settings are inside each one).
List<({IconData icon, String title, String subtitle, Widget page})> get _sections => [
      (icon: Icons.library_music_outlined, title: '音樂庫', subtitle: '音樂資料夾、掃描、檢查已不存在的歌曲、刪除方式、封面與歌手圖片', page: const LibrarySettingsPage()),
      (icon: Icons.play_circle_outline, title: '播放', subtitle: '等化器、淡入淡出、音量標準化、睡眠計時器', page: const PlaybackSettingsPage()),
      (icon: Icons.podcasts, title: 'Podcast', subtitle: '播放速度、跳過靜音、快轉秒數', page: const PodcastSettingsPage()),
      (
        icon: Icons.lyrics_outlined,
        title: '歌詞',
        subtitle: Platform.isAndroid ? '自動找歌詞、批次找歌詞、字體大小、車上和通知列顯示' : '自動找歌詞、批次找歌詞、字體大小',
        page: const LyricsSettingsPage()
      ),
      (icon: Icons.queue_music, title: '播放清單', subtitle: '智慧播放清單、允許重複', page: const PlaylistSettingsPage()),
      (
        icon: Icons.download_outlined,
        title: '下載與線上',
        subtitle: Platform.isAndroid ? '下載位置、Wi-Fi 提醒、yt-dlp、YouTube 金鑰' : '下載位置、yt-dlp、YouTube 金鑰',
        page: const DownloadSettingsPage()
      ),
      if (Platform.isAndroid) (icon: Icons.bluetooth_audio, title: '藍牙與車用', subtitle: '自動播放、藍牙裝置、Android Auto', page: const DevicesSettingsPage()),
      (icon: Icons.history, title: '播放紀錄與統計', subtitle: '播放紀錄、收聽統計、清除資料', page: const HistorySettingsPage()),
      if (syncAvailable) (icon: Icons.sync, title: '同步', subtitle: 'Google 雲端硬碟：選定的播放清單和歌曲在手機和電腦之間同步', page: const SyncSettingsPage()),
      (icon: Icons.backup_outlined, title: '備份與還原', subtitle: '手動備份、自動備份、從備份清單還原', page: const BackupPage()),
      (icon: Icons.storage_outlined, title: '儲存空間', subtitle: '封面、歌手圖片、歌詞、下載暫存檔佔用的空間', page: const StoragePage()),
      if (Platform.isWindows) (icon: Icons.keyboard_outlined, title: '快捷鍵', subtitle: '自訂電腦快捷鍵', page: const ShortcutSettingsEntry()),
      (icon: Icons.info_outline, title: '關於與更新', subtitle: '版本 $appVersion${Updater.supported ? ' • 檢查更新' : ''}', page: const AboutSettingsPage()),
    ];

/// 設定. Phone: one row per category (like Spotify), the settings inside.
/// Windows: everything on one page, with a contents list on the left.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    if (Platform.isWindows) return const _OnePageSettings();
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        for (final s in _sections) ...[
          if (s.title == '關於與更新') const Divider(),
          ListTile(
            leading: Icon(s.icon),
            title: Text(s.title, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(s.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: muted)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => s.page)),
          ),
        ],
      ]),
    );
  }
}

class _OnePageSettings extends StatefulWidget {
  const _OnePageSettings();

  @override
  State<_OnePageSettings> createState() => _OnePageSettingsState();
}

class _OnePageSettingsState extends State<_OnePageSettings> {
  final _sectionsNow = _sections;
  late final _keys = [for (final _ in _sectionsNow) GlobalKey()];
  final _list = GlobalKey();
  int _current = 0;

  /// While jumping, the entry clicked stays lit (short sections at the end
  /// never reach the top).
  bool _jumping = false;

  Future<void> _jump(int i) async {
    final c = _keys[i].currentContext;
    if (c == null) return;
    setState(() {
      _current = i;
      _jumping = true;
    });
    await Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    _jumping = false;
  }

  /// The section at the top of the list.
  void _track() {
    if (_jumping) return;
    final list = _list.currentContext?.findRenderObject() as RenderBox?;
    if (list == null) return;
    final top = list.localToGlobal(Offset.zero).dy;
    var at = 0;
    for (var i = 0; i < _keys.length; i++) {
      final box = _keys[i].currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.localToGlobal(Offset.zero).dy <= top + 48) at = i;
    }
    if (at != _current) setState(() => _current = at);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: 190,
          child: ListView(padding: const EdgeInsets.fromLTRB(8, 8, 8, 24), children: [
            for (var i = 0; i < _sectionsNow.length; i++)
              Hover(builder: (context, on) {
                final lit = on || i == _current;
                return ListTile(
                  dense: true,
                  hoverColor: Colors.transparent,
                  iconColor: i == _current ? cs.primary : (lit ? cs.onSurface : cs.onSurfaceVariant),
                  leading: Icon(_sectionsNow[i].icon, size: 20),
                  title: Text(_sectionsNow[i].title,
                      style: TextStyle(fontWeight: i == _current ? FontWeight.bold : FontWeight.w500, color: lit ? cs.onSurface : cs.onSurfaceVariant)),
                  onTap: () => _jump(i),
                );
              }),
          ]),
        ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (_) {
              _track();
              return false;
            },
            child: SingleChildScrollView(
              key: _list,
              padding: const EdgeInsets.only(bottom: 48),
              child: SettingsOnOnePage(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (var i = 0; i < _sectionsNow.length; i++) KeyedSubtree(key: _keys[i], child: _sectionsNow[i].page),
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
