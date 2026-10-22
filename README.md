# OuOPlayer

仿 Spotify 的跨平台音樂播放器（Flutter），支援 **Windows** 與 **Android**。

## 功能
- **播放**：播放/暫停/上下首、拖曳進度、音量、隨機、重複（全部/單曲）、佇列（拖曳排序、滑動刪除）、全螢幕播放頁（依封面取色的漸層背景）
- **背景播放與系統媒體控制**：Android 通知列、鎖定畫面、藍牙耳機/車機按鍵；Windows 媒體鍵與 SMTC
- **音樂庫**：掃描本機資料夾（讀取標籤與封面）、歌曲/專輯/演出者分類、搜尋、播放清單、已按讚的歌曲、最近播放
- **線上**：貼上網址直接串流、Podcast RSS 訂閱/串流/下載單集
- **下載器（仿 youtube-dl-gui）**：貼上網址（可多個、可整個播放清單）→ 選格式（MP3 / M4A / Opus / FLAC / 原始）→ 進度、取消、重試；完成後自動加入音樂庫
  - Windows：第一次使用時自動從官方 GitHub 下載 `yt-dlp.exe` 與 `ffmpeg`，可一鍵更新
  - Android：內建 youtubedl-android（Python + yt-dlp + ffmpeg），下載時以前景服務執行；可從其他 App「分享」連結到 OuOPlayer 直接下載
- **藍牙（Android）**：斷線自動暫停、連線自動續播（可關閉）、顯示目前輸出裝置、掃描/配對/連接藍牙耳機
- **外觀**：深色/淺色/跟隨系統，強調色 `#1DBEEF`；手機為底部分頁＋迷你播放器，寬螢幕為 Spotify 桌面版排版

> 請只下載你有權利保存的內容，並遵守來源網站的服務條款與著作權法。

## 開發環境（本機已安裝）
| 項目 | 位置 |
|---|---|
| Flutter SDK | `D:\dev\flutter`（已加入使用者 PATH） |
| Android SDK | `D:\dev\android-sdk`（`ANDROID_HOME`） |
| JDK 17 | `C:\Program Files\Microsoft\jdk-17.*` |
| VS 2022 Build Tools（C++ 桌面開發） | 預設位置 |

**注意：專案路徑含中文時 Flutter 分析器會出錯**，因此請透過英文路徑的連結資料夾 `D:\dev\ouoplayer`（指向本專案）執行所有 flutter 指令。

## 建置
```bash
cd D:/dev/ouoplayer
flutter pub get
flutter analyze
flutter test
flutter run -d windows                     # 開發執行
flutter build windows --release            # → build/windows/x64/runner/Release/OuOPlayer.exe
flutter build apk --release --split-per-abi  # → build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```
Windows 版需把整個 `Release` 資料夾一起複製才能執行。手機一般安裝 `app-arm64-v8a-release.apk`。

## 發佈版本
1. 修改 `pubspec.yaml` 的 `version:`（例如 `1.0.1+2`）
2. 執行：
   ```bash
   powershell -ExecutionPolicy Bypass -File scripts/release.ps1
   ```
3. 產出：
   - `release/windows/v<版本>/OuOPlayer/`（可直接執行的資料夾）與 `OuOPlayer-<版本>-windows-x64.zip`
   - `release/android/v<版本>/OuOPlayer-<版本>-<abi>.apk`（一般手機用 `arm64-v8a`）
4. 提交並打標籤：`git commit -am "Release v<版本>"`、`git tag v<版本>`

已存在的版本資料夾不會被覆蓋（要重建請加 `-Force`）。`release/` 不納入 git，避免儲存庫被大型執行檔塞滿。

## 專案結構
```
lib/
  main.dart / app.dart          啟動、主題、藍牙自動播放、分享連結
  theme/app_theme.dart          深/淺色主題
  data/                         Track 模型、sqflite 資料庫
  services/
    audio_handler.dart          just_audio + audio_service（佇列、背景播放、續播）
    library_scanner.dart        掃描資料夾、讀標籤封面
    podcast_service.dart        RSS 解析
    download_service.dart       下載佇列
    ytdlp/                      yt-dlp：Windows（Process）與 Android（原生橋接）
    bluetooth/                  藍牙 MethodChannel（Android）
  providers/providers.dart      Riverpod 狀態
  ui/                           AppShell、頁面與元件
android/app/src/main/kotlin/com/ouo/ouoplayer/
  MainActivity.kt               AudioServiceActivity + 註冊原生外掛
  YtDlpPlugin.kt                youtubedl-android 橋接
  BluetoothPlugin.kt            輸出裝置、掃描、配對、A2DP 連線事件
  DownloadForegroundService.kt  下載時的前景服務
```

## 已知限制
- Android 的「直接連接」藍牙裝置使用非公開 API，部分手機會拒絕，這時 App 會引導開啟系統藍牙設定。
- Android 版 APK 因內建 Python/ffmpeg 較大（每個 ABI 約 +30–40MB）。
- Release APK 目前使用 debug 簽章；要上架或長期使用請建立自己的簽章金鑰。
