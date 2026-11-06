import 'dart:io';

/// The demo copy used for README screenshots (built with
/// `--dart-define=OUO_DEMO=true` and OUO_DEMO=true for Gradle): its own app id
/// (com.ouo.ouoplayer.demo), only /sdcard/OuOPlayerDemo as its library, no
/// update checks. Windows (v1.17.4): its own database and only
/// %USERPROFILE%\OuOPlayerDemo. Never published.
const isDemo = bool.fromEnvironment('OUO_DEMO');

/// The Android package, which the demo copy changes.
const appPackage = isDemo ? 'com.ouo.ouoplayer.demo' : 'com.ouo.ouoplayer';

// Outside Music, so the real app (which scans Music) never sees the demo songs.
const demoFolder = '/storage/emulated/0/OuOPlayerDemo';

/// Windows: outside Music too, which the real app scans.
String get demoFolderWindows => '${Platform.environment['USERPROFILE'] ?? ''}\\OuOPlayerDemo';
