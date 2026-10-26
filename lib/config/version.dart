/// The version shown in 設定 → 關於與更新. scripts/release.ps1 passes it in
/// (`--dart-define=OUO_VERSION=…`), since the Windows build is numbered on
/// its own (e.g. Windows 0.5.0 next to Android 1.0.1). The default must match
/// pubspec.yaml for builds made without the script.
const appVersion = String.fromEnvironment('OUO_VERSION', defaultValue: '1.5.0');
