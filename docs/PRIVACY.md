# OuOPlayer 隱私權政策

最後更新：2026 年 11 月 1 日

OuOPlayer 是在 Android 和 Windows 上播放本機音樂的開源 App。它沒有廣告，不需要註冊帳號，開發者也沒有用來收集使用者資料的伺服器。

## 一般使用

播放清單、收聽紀錄、歌詞、封面和設定都存在你的裝置上。播放本機音樂不需要網路。

只有在下列情況會連網，而且只送出列出的資料：

| 用途 | 連到 | 送出的資料 |
|---|---|---|
| 找歌詞 | LRCLIB | 歌名、歌手、專輯、長度 |
| 歌手照片 | Deezer | 歌手名字 |
| 找封面、線上搜尋、Podcast 搜尋 | Apple iTunes | 歌名、歌手或搜尋文字 |
| 取得 YouTube Music 連結 | YouTube Data API | 歌名和歌手（只有你自己填了 API 金鑰才會用） |
| 檢查更新 | OuOPlayer 的更新伺服器 | 只送出更新檢查請求，不含你的音樂或帳號資料 |
| 下載、串流、Podcast | 你自己貼上或訂閱的網址 | 取得內容所需的請求 |

這些服務各有自己的隱私權政策，網路連線本身也會讓對方看到你的 IP 位址。

## Google 雲端硬碟同步

同步是選用功能，只有你在「設定 → 同步」登入 Google 帳號後才會啟用。

**App 使用的 Google 權限**

OuOPlayer 使用 Google Drive API 的 `drive.appdata` 權限。這個權限只能存取雲端硬碟裡 OuOPlayer 專用的隱藏資料夾，**無法看到你雲端硬碟裡的其他檔案**。

**會傳到你自己雲端硬碟的資料**

- 你勾選要同步的播放清單，以及「已按讚的歌曲」（如果有勾選）
- 這些清單裡的歌曲資訊：歌名、歌手、專輯、長度、封面
- 為了傳到另一台裝置而暫存的歌曲檔案，對方下載後會從雲端移除
- 你修改過的歌曲資料和歌詞
- 收聽紀錄：歌名、歌手、專輯、播放時間和收聽長度
- 接續播放資訊：正在播放的歌曲、位置和佇列
- 裝置名稱和最後上線時間，用來判斷每台裝置的同步狀態

**資料的去向**

這些資料直接在你的裝置和你自己的 Google 雲端硬碟之間傳輸，不會經過開發者的伺服器。開發者無法存取你的雲端硬碟，也看不到這些資料。登入憑證只存在你的裝置上。

OuOPlayer 不會出售 Google 使用者資料，不會用來投放廣告，也不會分享給第三方。OuOPlayer 對 Google API 取得資料的使用，遵守 [Google API 服務使用者資料政策](https://developers.google.com/terms/api-services-user-data-policy)，包括其中的「有限使用」要求，只用來提供你啟用的同步功能。

**如何停止與刪除**

- 在「設定 → 同步」登出，就會停止同步。
- 到 [Google 帳號的第三方連結](https://myaccount.google.com/connections) 移除 OuOPlayer，可撤銷存取權。
- 雲端資料存在你的雲端硬碟中，可以在 Google 雲端硬碟網頁版的「設定 → 管理應用程式」找到 OuOPlayer，選擇「刪除隱藏的應用程式資料」。
- 解除安裝 App 時，手機上的資料會一併移除；Windows 會詢問是否刪除。

## 兒童

OuOPlayer 不是專為兒童設計，也不會刻意收集兒童的資料。

## 政策變更

本政策有變更時會更新這個頁面和最後更新日期。

## 聯絡方式

有任何問題，請到 [GitHub Issues](https://github.com/HowardWang818/OuOPlayer/issues) 提出。

---

# OuOPlayer Privacy Policy

Last updated: November 1, 2026

OuOPlayer is an open-source app for playing local music on Android and Windows. It has no ads and needs no account, and the developer runs no server that collects user data.

## Everyday use

Playlists, listening history, lyrics, covers and settings stay on your device. Playing local music needs no network.

The app goes online only in these cases, and sends only what is listed:

| Purpose | Service | Data sent |
|---|---|---|
| Finding lyrics | LRCLIB | Title, artist, album, length |
| Artist photos | Deezer | Artist name |
| Finding covers, online search, podcast search | Apple iTunes | Title, artist or search text |
| YouTube Music links | YouTube Data API | Title and artist (only with your own API key) |
| Checking for updates | OuOPlayer's update server | An update request only, with none of your music or account data |
| Downloads, streams, podcasts | Addresses you enter or subscribe to | The requests needed to fetch them |

Each service has its own privacy policy, and any connection shows your IP address to that service.

## Google Drive sync

Sync is optional and starts only after you sign in to Google in Settings → Sync.

**The Google permission used**

OuOPlayer uses the Google Drive API `drive.appdata` scope. It reaches only OuOPlayer's own hidden folder in Drive, and **cannot see any of your other Drive files**.

**What goes to your own Google Drive**

- The playlists you choose to sync, and Liked Songs if you choose it
- Song details in those playlists: title, artist, album, length, cover
- Song files held for your other device, removed once that device has them
- Song details and lyrics you edited
- Listening history: title, artist, album, time played and time listened
- Resume information: the current song, position and queue
- Device name and last seen time, used to track each device's sync

**Where it goes**

This data travels directly between your devices and your own Google Drive, not through any server of the developer. The developer has no access to your Drive and cannot see this data. Sign-in credentials stay on your device.

OuOPlayer does not sell Google user data, use it for advertising, or share it with third parties. OuOPlayer's use of information received from Google APIs adheres to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements, and serves only the sync you turned on.

**Stopping and deleting**

- Sign out in Settings → Sync to stop syncing.
- Remove OuOPlayer from [your Google Account's third-party connections](https://myaccount.google.com/connections) to revoke access.
- The cloud data lives in your Drive: on the Google Drive website, open Settings → Manage Apps, find OuOPlayer and choose Delete hidden app data.
- Uninstalling removes the app's data on a phone; on Windows the uninstaller asks.

## Children

OuOPlayer is not designed for children and does not knowingly collect their data.

## Changes

Changes to this policy are posted on this page with a new date.

## Contact

Please open an issue at [GitHub Issues](https://github.com/HowardWang818/OuOPlayer/issues).
