/// Google Drive sync (同步): the OAuth client of the OuOPlayer project in
/// Google Cloud for the Windows app. It's passed in when building
/// (scripts/release.ps1 reads it from the keys folder, outside the public
/// repository), so builds without it simply have no sync on Windows.
/// The phone needs no ID here: Google Play services finds the Android client
/// by package name and signing key.
const googleDesktopClientId = String.fromEnvironment('OUO_GOOGLE_DESKTOP_ID');
const googleDesktopClientSecret = String.fromEnvironment('OUO_GOOGLE_DESKTOP_SECRET');

/// Only the app's own hidden folder in the user's Drive.
const driveAppDataScope = 'https://www.googleapis.com/auth/drive.appdata';

/// Files the app made itself (雲端音樂庫: a folder the user can see); never
/// the user's other files.
const driveFileScope = 'https://www.googleapis.com/auth/drive.file';
