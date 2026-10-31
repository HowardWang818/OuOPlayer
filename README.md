<p align="right"><a href="README.en.md">English</a></p>

<p align="center">
  <img src="assets/icon/app_icon_dark.png" width="96" alt="OuOPlayer">
</p>

<h1 align="center">OuOPlayer</h1>

<p align="center">
  像串流 App 一樣好用的本機音樂播放器<br>
  Android ・ Windows ・ 免費 ・ 開源（GPL-3.0）・ 沒有廣告，不收集任何資料
</p>

<p align="center">
  <a href="https://github.com/HowardWang818/OuOPlayer/releases/latest"><b>下載最新版</b></a>
</p>

## 截圖

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/dark_home.jpg" width="250"><br>首頁</td>
    <td align="center"><img src="docs/screenshots/dark_list.jpg" width="250"><br>音樂庫</td>
    <td align="center"><img src="docs/screenshots/dark_lyrics.jpg" width="250"><br>同步歌詞</td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/light_home.jpg" width="250"><br>首頁（淺色）</td>
    <td align="center"><img src="docs/screenshots/light_list.jpg" width="250"><br>音樂庫（淺色）</td>
    <td align="center"><img src="docs/screenshots/light_lyrics.jpg" width="250"><br>同步歌詞（淺色）</td>
  </tr>
</table>

<sub>截圖裡的歌手、歌曲和封面都是虛構的示範資料。</sub>

## 下載

到 [Releases](https://github.com/HowardWang818/OuOPlayer/releases/latest) 下載：

| 平台 | 檔案 | 說明 |
|---|---|---|
| Android 7.0 以上 | `OuOPlayer-<版本>-arm64-v8a.apk` | 一般手機用這個，之後可以在 App 裡直接更新 |
| Windows 64 位元 | `OuOPlayer-<版本>-windows-setup.exe` | 安裝版，之後可以在 App 裡直接更新 |
| Windows 64 位元 | `OuOPlayer-<版本>-windows-x64.zip` | 解壓版，解壓縮後直接執行，新版本要自己下載 |

## 功能

**播放**
- 背景播放，通知列、鎖定畫面、藍牙耳機和車機按鍵都能控制
- 等化器、音量標準化、播放／暫停淡入淡出、睡眠計時器
- 佇列可以拖曳排序，播完後可以接著隨機播放
- 隨機播放時，沒播過的歌優先

**手機和電腦同步**
- 用自己的 Google 雲端硬碟同步勾選的播放清單，手機和電腦之間自動傳歌
- 改過的歌曲資料、歌詞和收聽紀錄也會同步
- 接續播放：在另一台從同一首歌、同一個位置接著聽

**Windows**
- 側邊欄、右側播放面板和全螢幕播放頁，版面可以自己拖曳調整
- 快捷鍵可以自訂，支援鍵盤媒體鍵
- 關閉視窗時縮到系統匣繼續播放，也能開機自動啟動

**音樂庫**
- 自動掃描手機或電腦裡的音樂，依專輯、歌手、歌曲分類
- 照資料夾瀏覽，可以直接新增、重新命名、刪除資料夾，或把歌移到別的資料夾
- 替沒有封面的歌找正式封面；自動抓歌手照片，也可以自己換圖、改名
- 多選後一次編輯資訊、加入播放清單、隱藏或刪除

**播放清單**
- 自訂播放清單和資料夾、自訂封面
- 智慧播放清單：最常播放、最近加入、很久沒聽、從沒播過
- 匯入 M3U，以及 Spotify 的歌單（資料匯出檔或 Exportify CSV）；手機裡沒有的歌會先保留位置，之後有了自動補上

**歌詞**
- 同步歌詞跟著播放捲動，點一行就跳到那裡
- 依序從歌曲檔案、同名 `.lrc` 檔、[LRCLIB](https://lrclib.net) 找歌詞；可以替整個音樂庫或一個播放清單一次找好
- 日文和中文歌優先使用原文歌詞，不會抓到羅馬拼音版
- 可以在 Android Auto 和通知列顯示正在唱的那一句

**Podcast**
- 搜尋、訂閱、下載單集
- 記住每一集聽到哪裡，可以調整播放速度、跳過靜音

**車上與藍牙（Android）**
- 支援 Android Auto，可以瀏覽播放清單、專輯、Podcast，也能用語音搜尋
- 藍牙耳機連上時自動接著播，斷線時自動暫停

**其他**
- 收聽統計和年度回顧
- 手動備份，或照你選的時間自動備份；還原時可以只挑一部分（例如只還原設定）
- 桌面小工具（4x1 和 2x2，Android）
- 深色、淺色主題，Android 的 App 圖示也可以換成淺色或跟著主題變
- App 內直接更新（Android 和 Windows 安裝版）

**下載**
- 貼上網址下載音訊（使用 [yt-dlp](https://github.com/yt-dlp/yt-dlp)），下載完自動加進音樂庫。
- 請只下載你有權利保存的內容，並遵守來源網站的服務條款。

## 常見問題

<details>
<summary>手機和電腦要怎麼同步？</summary>

兩邊都到「設定 → 同步」用同一個 Google 帳號登入，再勾選要同步的播放清單。資料存在你自己雲端硬碟的 App 專用資料夾，App 看不到你的其他檔案。傳歌會暫時佔用雲端硬碟空間，另一台下載後就會移除。
</details>

<details>
<summary>Android Auto 裡看不到 OuOPlayer？</summary>

Android Auto 預設只顯示從 Play 商店安裝的 App，要先開啟「不明來源」：

1. 打開手機的 Android Auto 設定（在系統設定裡搜尋「Android Auto」）。
2. 往下找到「版本」，連續點約 10 次，允許開啟開發人員設定。
3. 右上角「⋮」→「開發人員設定」→ 勾選「不明來源」。
4. 重新連接車子。
</details>

<details>
<summary>為什麼要「媒體管理」權限？</summary>

刪除或移動不是 OuOPlayer 下載的歌時，Android 每次都會跳出確認視窗。開啟「媒體管理」（設定 → 音樂庫）後就不用每次確認。不開也可以正常使用。
</details>

<details>
<summary>刪掉的歌去哪了？</summary>

Android 預設會移到系統的垃圾桶，大約 30 天內可以從「檔案」App 還原；Windows 會移到資源回收筒。如果在「設定 → 音樂庫」開啟「刪除檔案時直接永久刪除」，就無法還原。
</details>

<details>
<summary>歌詞找不到，或找到別首歌的？</summary>

在歌詞畫面按「不對？手動搜尋」，可以修改歌名和歌手重新搜尋，選好的歌詞會一直保留。
</details>

<details>
<summary>換手機怎麼搬資料？</summary>

在舊手機用「設定 → 備份與還原 → 備份資料」存成一個檔案，到新手機用「從檔案還原」。播放清單、按讚、播放次數、Podcast 和設定都會搬過去，歌曲會依檔案位置或歌名、歌手自動對上。
</details>

## 隱私

OuOPlayer 不需要帳號，沒有廣告，開發者也不會收集任何使用資料。播放本機音樂完全不用網路。完整內容請看[隱私權政策](docs/PRIVACY.md)。

只有下列情況會連網，而且只會送出列出的資料：

| 用途 | 連到 | 送出的資料 | 怎麼關 |
|---|---|---|---|
| 找歌詞 | LRCLIB | 歌名、歌手、專輯、長度 | 設定 → 歌詞 |
| 歌手照片 | Deezer | 歌手名字 | 設定 → 音樂庫 |
| 找正式封面、線上搜尋、Podcast 搜尋 | Apple iTunes | 歌名、歌手或搜尋文字 | 只在你使用時才會連 |
| 取得 YouTube Music 連結 | YouTube Data API | 歌名和歌手 | 只有你自己填了 API 金鑰才會用 |
| 雲端同步 | 你自己的 Google 雲端硬碟 | 勾選的播放清單、歌曲資訊和檔案、歌詞、收聽紀錄 | 預設關閉，設定 → 同步 |
| 檢查更新 | OuOPlayer 的更新伺服器 | 只送出更新檢查請求 | 設定 → 關於與更新 |
| 下載、串流、Podcast | 你自己貼上或訂閱的網址 | — | 只在你使用時才會連 |

## 授權

OuOPlayer 以 [GNU General Public License v3.0](LICENSE) 授權釋出。

感謝這些開源專案和服務：
[Flutter](https://flutter.dev)、
[just_audio](https://pub.dev/packages/just_audio)、
[audio_service](https://pub.dev/packages/audio_service)、
[media_kit](https://github.com/media-kit/media-kit)、
[yt-dlp](https://github.com/yt-dlp/yt-dlp)、
[youtubedl-android](https://github.com/JunkFood02/youtubedl-android)、
[LRCLIB](https://lrclib.net)、
[RapidFuzz](https://pub.dev/packages/rapidfuzz)、
[Riverpod](https://riverpod.dev)、
[sqflite](https://pub.dev/packages/sqflite)。

## 給開發者

建置方式、版本規則和發布流程請看 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。

這個專案的程式碼大部分是和 AI（Claude）一起寫的，設計、測試和每個版本的取捨由 HowardWang818 決定。
