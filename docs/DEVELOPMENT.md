# OuOPlayer 開發說明

用 [Flutter](https://flutter.dev) 寫的音樂播放器，同一份程式碼可以建置 Android 和 Windows。兩邊用同一個版本號（從 1.14.1 起）。

## 開發環境

| 工具 | 版本 |
|---|---|
| Flutter | stable（Dart 3.x） |
| Android SDK | compileSdk 37、minSdk 24（Android 7.0） |
| JDK | 17（Gradle 不支援更新的版本） |
| Windows 版（選用） | Visual Studio 2022 Build Tools，「使用 C++ 的桌面開發」 |
| Windows 安裝檔（選用） | [Inno Setup 6](https://jrsoftware.org/isinfo.php)，`release.ps1` 預設找 `D:\dev\InnoSetup\ISCC.exe` |
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

**Windows 的 `windows/runner/Runner.rc` 不要改公司名稱、產品名稱，也不要改版本資訊的語言區塊**（必須是英文 `040904b0`）：Windows 版的資料放在 `%APPDATA%\com.ouo\OuOPlayer`，這個路徑就是從那裡讀出來的，改了 App 會打開一個空的音樂庫（1.15.0 發生過）。`test/v1151_test.dart` 會檢查。

## 版本規則

從 0.0.0 起算，格式 `主.次.修`：

- **修**（第三位）：小更新、修 bug。
- **次**（第二位）：新功能或大更新。
- **主**（第一位）：正式版才會用到。

`pubspec.yaml` 的 `+` 後面是建置編號，每次發布都要加 1（Android 只接受編號更大的更新）。「關於與更新」頁和 Windows 更新比對用的版本在 `lib/config/version.dart`（`release.ps1` 會用 `--dart-define=OUO_VERSION` 傳進去），預設值要和 `pubspec.yaml` 同步。

## 發布流程

1. 改 `pubspec.yaml` 的版本和 `lib/config/version.dart` 的預設值，並把這版的重點寫進 `assets/whats_new.txt`（更新後第一次打開時顯示，最多 8 行）。
2. `flutter analyze`、`flutter test`。
3. 建置兩邊（`-WindowsOnly` 只建 Windows；不加參數只建 Android）：
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts/release.ps1 -Windows
   ```
   產出：
   - `release/android/v<版本>/OuOPlayer-<版本>-<abi>.apk`
   - `release/windows/v<版本>/`：`OuOPlayer-<版本>-windows-setup.exe`（Inno Setup 安裝檔，`windows/installer/OuOPlayer.iss`）、`OuOPlayer-<版本>-windows-x64.zip`（解壓版）和 `OuOPlayer/` 資料夾

   已經存在的版本資料夾不會被覆蓋（`-Force` 只在確定要覆蓋時用）。`release/` 不進 git。
4. 在手機和電腦上測試。
5. commit、打 `v<版本>` 標籤、推送。
6. 寫更新內容：手機 `release/notes/v<版本>.md`、GitHub `release/notes/github-v<版本>.md`、Windows App 內 `release/notes/windows-v<版本>.md`。
7. 發布，依這個順序：
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts/publish.ps1 -SkipR2       # GitHub Release（APK、安裝檔、zip）
   powershell -ExecutionPolicy Bypass -File scripts/publish.ps1 -SkipGitHub   # 手機 App 內更新（R2 的 latest.json）
   powershell -ExecutionPolicy Bypass -File scripts/publish.ps1 -Windows      # 電腦 App 內更新（R2 的 latest-windows.json）
   ```
   更新伺服器每個平台只保留最新 3 版；`latest*.json` 最後才上傳。
8. 換 youtubedl-android 版本時，先上傳 APK 不再內含的下載元件（Python、ffmpeg），再發布那個 APK：
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts/publish.ps1 -Components
   ```
   並更新 `lib/services/ytdlp/ytdlp_android.dart` 裡的大小和 SHA-256。

## 簽章金鑰

Android 只接受用**同一把金鑰**簽的更新，所以 release 建置固定使用 `D:/dev/ouoplayer-keys/ouoplayer.keystore`（可以用環境變數 `OUO_KEYSTORE` 指定別的位置），見 `android/app/build.gradle.kts`。找不到這個檔案時，`release.ps1` 會直接停止，避免換成一把新的金鑰。

金鑰檔不會進 git。**自己 fork 的版本請用自己的金鑰**，並改掉下面的更新伺服器網址。

金鑰的密碼放在金鑰旁邊的 `key.properties`（`storePassword=…`、`keyPassword=…`，可加 `keyAlias=…`），沒有這個檔案時用 debug 金鑰原本的 `android`。改密碼不會改變簽章，已安裝的 App 照樣能更新：

```powershell
keytool -storepasswd -keystore D:\dev\ouoplayer-keys\ouoplayer.keystore
keytool -keypasswd -alias androiddebugkey -keystore D:\dev\ouoplayer-keys\ouoplayer.keystore
```

## 建置時帶入的金鑰

都放在 `D:\dev\ouoplayer-keys\`，由 `release.ps1` 帶進去，不進 git：

- `google_oauth.json`：Windows 版的 Google 登入（`desktopClientId`、`desktopClientSecret`）。

## App 內更新與更新伺服器

- App 端：`lib/services/updater.dart`、`lib/ui/widgets/update_dialog.dart`，伺服器網址在 `lib/config/update_config.dart`。App 讀 `latest.json`，下載適合手機 ABI 的 APK，比對 SHA-256 後交給 Android 安裝。
- 伺服器端：`cloud/update-worker/`，是一個放在私人 Cloudflare R2 bucket 前面的 Cloudflare Worker。
  - 只回應帶有 App 標頭的 `GET /latest.json`、`/v<版本>/OuOPlayer-<版本>-<abi>.apk`、`/latest-windows.json`、`/windows/v<版本>/OuOPlayer-<版本>-windows-setup.exe` 和 `/components/ytdlp-<版本>/<abi>/{python,ffmpeg}.zip`，其他一律 404。
  - Windows 安裝版：App 讀 `latest-windows.json`，下載安裝檔、比對 SHA-256 後靜默安裝再重新開啟；解壓版會開啟 GitHub Releases。
  - 每個 IP 每分鐘的次數有限制。
  - 使用 Workers 免費方案：每天超過 10 萬次請求只會暫停，不會產生費用。
  - 部署：在 `cloud/update-worker/` 執行 `npx wrangler login`，再執行 `npx wrangler deploy`。
  - 匿名使用人數（1.18.0 起）：App 每天一次 `GET /hello`，帶隨機代碼、版本、平台，存在 D1（`schema.sql`），保留 90 天，不存 IP。第一次要建資料庫並設定看統計的密碼，步驟寫在 `wrangler.toml` 最後面；之後在瀏覽器開 `/stats?key=<密碼>` 看每天人數和版本分布。沒有設定 D1 時 `/hello` 只回應、不記錄。

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
