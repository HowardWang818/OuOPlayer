/// The version shown in 設定 → 關於與更新, and what Windows updates compare.
/// scripts/release.ps1 passes it in (`--dart-define=OUO_VERSION=…`). The
/// default must match pubspec.yaml for builds made without the script.
const appVersion = String.fromEnvironment('OUO_VERSION', defaultValue: '1.14.3');
