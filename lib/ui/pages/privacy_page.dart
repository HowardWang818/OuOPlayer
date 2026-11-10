import 'package:flutter/material.dart';

import '../../config/links.dart';
import '../widgets/links.dart';

/// 隱私說明: a short version of docs/PRIVACY.md (the full policy).
class PrivacyPage extends StatelessWidget {
  const PrivacyPage({super.key});

  static const sections = <(String, String)>[
    ('簡單說', 'OuOPlayer 不需要帳號、沒有廣告，也不會收集你的音樂庫、播放紀錄或個人資料。你的資料都留在你的手機和電腦上。'),
    ('同步', '登入 Google 後，同步的播放清單、按讚、歌詞、播放紀錄、主題和要傳的歌，都存在你自己 Google 雲端硬碟裡的「App 專用資料夾」。這個資料夾只有 OuOPlayer 讀得到，開發者看不到。登出或在雲端硬碟設定裡移除 OuOPlayer 就會停止。'),
    ('匿名使用人數', '每天第一次打開 App 時，OuOPlayer 會送一組隨機產生的代碼、版本號和平台（Android 或 Windows）到更新伺服器，只用來統計每天大約有多少人在用、用哪個版本。這組代碼和你的身分、帳號、裝置都沒有關係，伺服器也不記錄 IP 位址，資料保留 90 天。可以在 設定 → 關於與更新 關掉，關掉後就不再送出，代碼也會刪除。'),
    ('會連到的網路服務', '只有在用到相關功能時才會連線，送出的只有找東西需要的資料（例如歌名、歌手）：\n'
        '• 歌詞：LRCLIB\n'
        '• 封面、Podcast 搜尋：Apple iTunes\n'
        '• 歌手照片：Deezer\n'
        '• 原文歌名：mora、OTOTOY、YouTube Music\n'
        '• 下載：你貼上的網址（透過 yt-dlp），Windows 版第一次使用時會從 GitHub 下載 yt-dlp 和 ffmpeg\n'
        '• 取得 YouTube Music 連結：YouTube Data API（用你自己申請的金鑰）\n'
        '• Last.fm／ListenBrainz：你開啟播放記錄時，送出播放的歌名、歌手和時間\n'
        '• 同步：Google 雲端硬碟\n'
        '• 檢查更新和下載元件：OuOPlayer 的更新伺服器（Cloudflare）'),
    ('權限', '讀取音樂和檔案：找到並播放你的歌。通知：播放控制和下載進度。藍牙：連上耳機時自動播放（可以關）。安裝 App：App 內更新。'),
    ('開源', 'OuOPlayer 以 GPL-3.0 授權開源，所有程式碼都可以在 GitHub 上檢查。'),
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
            label: const Text('完整的隱私權政策'),
          ),
        ),
      ]),
    );
  }
}
