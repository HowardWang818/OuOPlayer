# OuOPlayer 開發說明

用 [Flutter](https://flutter.dev) 寫的音樂播放器，同一份程式碼可以建置 Android 和 Windows。目前以 Android 為主。

## 開發環境

| 工具 | 版本 |
|---|---|
| Flutter | stable（Dart 3.x） |
| Android SDK | compileSdk 37、minSdk 24（Android 7.0） |
| JDK | 17（Gradle 不支援更新的版本） |
| Windows 版（選用） | Visual Studio 2022 Build Tools，「使用 C++ 的桌面開發」 |
| 圖示（選用） | Python 3 + Pillow |

**專案路徑不能有中文或其他非 ASCII 字元**，Flutter 分析器和 Gradle 會出錯。專案放在中文路徑時，請建一個英文路徑的連結資料夾，從那裡執行所有 flutter 指令：

```powershell
New-Item -ItemType Junction -Path D:\dev\ouoplayer -Target "<專案路徑>"
```

## 建置與測試

```bash
flutter pub get
flutter analyze
flutter test
flutter run                                   # 接著手機開發
flutter build apk --release --split-per-abi    # → build/app/outputs/flutter-apk/
flutter build windows --release                # → build/windows/x64/runner/Release/
```

Windows 版要把整個 `Release` 資料夾一起複製才能執行。

## 版本規則

從 0.0.0 起算，格式 `主.次.修`：

- **修**（第三位）：小更新、修 bug。
- **次**（第二位）：新功能或大更新。
- **主**（第一位）：正式版才會用到。

`pubspec.yaml` 的 `+` 後面是建置編號，每次發布都要加 1（Android 只接受編號更大的更新）。「關於與更新」頁顯示的版本字串在 `lib/ui/pages/settings_page.dart` 和 `lib/ui/pages/settings/about_settings.dart`，要和 `pubspec.yaml` 同步。

## 發布流程

1. 改 `pubspec.yaml` 的版本和上面兩個版本字串。
2. `flutter analyze`、`flutter test`。
3. 建置（只建 Android；加 `-Windows` 才會一起建 Windows）：
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts/release.ps1
   ```
   產出在 `release/android/v<版本>/OuOPlayer-<版本>-<abi>.apk`（Windows 在 `release/windows/v<版本>/`）。已經存在的版本資料夾不會被覆蓋。`release/` 不進 git。
4. 在手機上測試。
5. commit、打 `v<版本>` 標籤、推送。
6. 寫更新內容到 `release/notes/v<版本>.md`，然後發布：
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts/publish.ps1
   ```
   會把 APK 上傳到更新伺服器（最後才上傳 `latest.json`，伺服器只保留最新 3 版），並建立 GitHub Release。`-SkipR2`、`-SkipGitHub` 可以只做其中一邊。

## 簽章金鑰

Android 只接受用**同一把金鑰**簽的更新，所以 release 建置固定使用 `D:/dev/ouoplayer-keys/ouoplayer.keystore`（可以用環境變數 `OUO_KEYSTORE` 指定別的位置），見 `android/app/build.gradle.kts`。找不到這個檔案時，`release.ps1` 會直接停止，避免換成一把新的金鑰。

金鑰檔不會進 git。**自己 fork 的版本請用自己的金鑰**，並改掉下面的更新伺服器網址。

## App 內更新與更新伺服器

- App 端：`lib/services/updater.dart`、`lib/ui/widgets/update_dialog.dart`，伺服器網址在 `lib/config/update_config.dart`。App 讀 `latest.json`，下載適合手機 ABI 的 APK，比對 SHA-256 後交給 Android 安裝。
- 伺服器端：`cloud/update-worker/`，是一個放在私人 Cloudflare R2 bucket 前面的 Cloudflare Worker。
  - 只回應帶有 App 標頭的 `GET /latest.json` 和 `GET /v<版本>/OuOPlayer-<版本>-<abi>.apk`，其他一律 404。
  - 每個 IP 每分鐘的次數有限制。
  - 使用 Workers 免費方案：每天超過 10 萬次請求只會暫停，不會產生費用。
  - 部署：在 `cloud/update-worker/` 執行 `npx wrangler login`，再執行 `npx wrangler deploy`。

## 圖示

App 圖示是用程式畫的（不是點陣圖），改 `assets/icon/make_icon.py` 裡的數字再重新產生：

```bash
python assets/icon/make_icon.py          # 深色和淺色兩組圖、Android 淺色圖示資源
dart run flutter_launcher_icons          # 深色圖示的 Android / Windows 各種尺寸
```

淺色圖示是另一個 activity-alias（`.LightIcon`），由「設定 → 關於與更新 → App 圖示」切換。

## 示範版（截圖用）

README 的截圖來自另一個獨立的示範版（`com.ouo.ouoplayer.demo`），只會讀 `/sdcard/OuOPlayerDemo` 裡的示範歌曲，也不會檢查更新：

```powershell
$env:OUO_DEMO = 'true'
flutter build apk --release --target-platform android-arm64 --dart-define=OUO_DEMO=true
```

第一次啟動並掃描完示範歌曲後，`lib/config/demo_seed.dart` 會建立示範播放清單和播放紀錄。示範版不會發布。

## 專案結構

```
lib/
  main.dart / app.dart         啟動、主題、各種背景監聽（藍牙、小工具、自動備份、更新…）
  config/                      更新伺服器、示範版設定
  data/                        資料模型、sqflite 資料庫
  providers/                   Riverpod 狀態
  services/
    audio_handler.dart         just_audio + audio_service（佇列、背景播放、Android Auto）
    library_scanner.dart       掃描資料夾、讀取標籤和封面
    song_matcher.dart          歌名／歌手比對（下載重複、歌單匯入、備份還原、歌詞）
    artists.dart               歌手拆分、別名、改名
    lyrics/                    歌詞（標籤、.lrc、LRCLIB）
    download_service.dart      下載佇列
    ytdlp/                     yt-dlp：Windows（外部程式）與 Android（youtubedl-android）
    backup.dart / auto_backup.dart
    folder_ops.dart            新增、重新命名、刪除資料夾，移動歌曲
    updater.dart               App 內更新
  ui/                          頁面與元件（設定頁在 ui/pages/settings/）
android/app/src/main/kotlin/com/ouo/ouoplayer/
  MainActivity.kt              註冊各個原生外掛
  YtDlpPlugin.kt               youtubedl-android 橋接
  TrashPlugin.kt               垃圾桶、刪除、移動檔案、寫入標籤（MediaStore）
  PlayerWidgetProvider.kt      桌面小工具
  ArtProvider.kt               提供封面給 Android Auto
  UpdatePlugin.kt / IconPlugin.kt / CarConnectionPlugin.kt
cloud/update-worker/           更新伺服器（Cloudflare Worker）
scripts/                       release.ps1、publish.ps1
third_party/just_audio_media_kit/  修改過的 just_audio_media_kit（Windows 音量標準化）
```

## 已知限制

- Android 的「直接連接藍牙裝置」用的是非公開 API，部分手機會拒絕，這時 App 會改開系統的藍牙設定。
- APK 因為內建 Python、yt-dlp 和 ffmpeg，每個 ABI 大約 60 MB。
- Android Auto 只顯示從 Play 商店安裝的 App，側載的版本要先在 Android Auto 開啟「不明來源」。
