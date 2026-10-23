import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../../theme/app_theme.dart';
import '../widgets/links.dart';

/// Step-by-step guide for getting a YouTube Data API key, with a field to
/// paste it and a button that tests it with one real search.
class YouTubeKeyGuidePage extends ConsumerStatefulWidget {
  const YouTubeKeyGuidePage({super.key});

  @override
  ConsumerState<YouTubeKeyGuidePage> createState() => _YouTubeKeyGuidePageState();
}

class _YouTubeKeyGuidePageState extends ConsumerState<YouTubeKeyGuidePage> {
  late final _ctrl = TextEditingController(text: ref.read(settingsProvider).youtubeApiKey);
  bool _testing = false;
  String? _result;
  bool _ok = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    final key = _ctrl.text.trim();
    final settings = ref.read(settingsProvider.notifier);
    // An empty field clears the stored key.
    if (key.isEmpty) {
      settings.setYoutubeApiKey('');
      setState(() {
        _ok = true;
        _result = '已清除金鑰';
      });
      return;
    }
    setState(() {
      _testing = true;
      _result = null;
    });
    try {
      await ref.read(youTubeLinkFinderProvider).testKey(key);
      // Only a key that actually works gets stored.
      settings.setYoutubeApiKey(key);
      setState(() {
        _ok = true;
        _result = '✓ 可以使用，已儲存';
      });
    } catch (e) {
      setState(() {
        _ok = false;
        _result = '✗ $e';
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    Widget step(int n, String title, String body, {String? button, String? url}) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: AppColors.accent,
              child: Text('$n', style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(body, style: TextStyle(color: muted, height: 1.5)),
                if (button != null && url != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: Text(button),
                      onPressed: () => openExternal(context, url),
                    ),
                  ),
              ]),
            ),
          ]),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('申請 YouTube 金鑰')),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        Card(
          margin: const EdgeInsets.all(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('開始前', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              Text(
                '• 需要一個 Google 帳號，約 5 分鐘\n'
                '• 免費：每天約可搜尋 100 次，超過不會收費，只會暫停到隔天\n'
                '• 金鑰只存在這台裝置，不會上傳到任何地方\n'
                '• 用途只有「取得 YouTube Music 連結」，OuOPlayer 不會播放或下載 YouTube 內容',
                style: TextStyle(color: muted, height: 1.6),
              ),
            ]),
          ),
        ),
        step(1, '建立專案', '開啟 Google Cloud Console，點左上角的專案選單 →「新增專案」，名稱隨意（例如 OuOPlayer）→ 建立，並確認上方已切換到這個專案。',
            button: '開啟 Google Cloud Console', url: 'https://console.cloud.google.com/projectcreate'),
        step(2, '啟用 YouTube Data API v3', '開啟 API 頁面，確認上方是剛建立的專案，按「啟用」。',
            button: '開啟 YouTube Data API v3', url: 'https://console.cloud.google.com/apis/library/youtube.googleapis.com'),
        step(3, '建立 API 金鑰', '開啟「憑證」頁面 →「建立憑證」→「API 金鑰」，畫面會顯示一串金鑰，按旁邊的按鈕複製。',
            button: '開啟憑證頁面', url: 'https://console.cloud.google.com/apis/credentials'),
        step(4, '（建議）限制金鑰', '在金鑰的設定裡，把「API 限制」設為「限制金鑰」，只勾選 YouTube Data API v3 後儲存。這樣金鑰就算外流，也只能用來查 YouTube。'),
        step(5, '貼上並測試', '把金鑰貼到下面，按「測試金鑰」。OuOPlayer 會實際查詢一次，確認可以使用後就會儲存。'),
        Padding(
          padding: const EdgeInsets.fromLTRB(56, 8, 16, 0),
          child: TextField(
            controller: _ctrl,
            decoration: const InputDecoration(hintText: '貼上 API 金鑰（AIza 開頭）', prefixIcon: Icon(Icons.key)),
            keyboardType: TextInputType.visiblePassword,
            autocorrect: false,
            enableSuggestions: false,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(56, 12, 16, 0),
          child: Row(children: [
            FilledButton.icon(
              onPressed: _testing ? null : _test,
              icon: _testing
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check),
              label: const Text('測試金鑰'),
            ),
            const SizedBox(width: 12),
            if (_result != null)
              Expanded(child: Text(_result!, style: TextStyle(color: _ok ? AppColors.accent : Colors.redAccent))),
          ]),
        ),
      ]),
    );
  }
}
