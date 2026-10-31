import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';

/// Windows: what a key can do (設定 → 快捷鍵).
enum AppAction {
  playPause('播放／暫停'),
  playPause2('播放／暫停（第二組）'),
  previous('上一首'),
  next('下一首'),
  back('倒退', repeats: true),
  forward('快轉', repeats: true),
  volumeUp('音量調大', repeats: true),
  volumeDown('音量調小', repeats: true),
  mute('靜音'),
  lyrics('顯示／隱藏歌詞'),
  search('搜尋'),
  filter('清單內篩選'),
  selectAll('全選'),
  nowPlaying('正在播放'),
  queue('佇列'),
  home('首頁'),
  settings('設定'),
  help('快捷鍵一覽');

  const AppAction(this.label, {this.repeats = false});
  final String label;

  /// Keeps going while the key is held.
  final bool repeats;
}

final _escape = PhysicalKeyboardKey.escape.usbHidUsage;

/// The keys that can be used, by USB code. The physical key, not the letter it
/// types, so shortcuts still work while a Chinese input method is on.
final Map<int, String> keyNames = {
  for (var i = 0; i < 26; i++) PhysicalKeyboardKey.keyA.usbHidUsage + i: String.fromCharCode(65 + i),
  for (var i = 0; i < 9; i++) PhysicalKeyboardKey.digit1.usbHidUsage + i: '${i + 1}',
  PhysicalKeyboardKey.digit0.usbHidUsage: '0',
  for (var i = 0; i < 12; i++) PhysicalKeyboardKey.f1.usbHidUsage + i: 'F${i + 1}',
  PhysicalKeyboardKey.space.usbHidUsage: 'Space',
  PhysicalKeyboardKey.arrowLeft.usbHidUsage: '←',
  PhysicalKeyboardKey.arrowRight.usbHidUsage: '→',
  PhysicalKeyboardKey.arrowUp.usbHidUsage: '↑',
  PhysicalKeyboardKey.arrowDown.usbHidUsage: '↓',
  PhysicalKeyboardKey.slash.usbHidUsage: '/',
  PhysicalKeyboardKey.backslash.usbHidUsage: r'\',
  PhysicalKeyboardKey.comma.usbHidUsage: ',',
  PhysicalKeyboardKey.period.usbHidUsage: '.',
  PhysicalKeyboardKey.semicolon.usbHidUsage: ';',
  PhysicalKeyboardKey.quote.usbHidUsage: "'",
  PhysicalKeyboardKey.minus.usbHidUsage: '-',
  PhysicalKeyboardKey.equal.usbHidUsage: '=',
  PhysicalKeyboardKey.bracketLeft.usbHidUsage: '[',
  PhysicalKeyboardKey.bracketRight.usbHidUsage: ']',
  PhysicalKeyboardKey.backquote.usbHidUsage: '`',
  PhysicalKeyboardKey.home.usbHidUsage: 'Home',
  PhysicalKeyboardKey.end.usbHidUsage: 'End',
  PhysicalKeyboardKey.pageUp.usbHidUsage: 'PageUp',
  PhysicalKeyboardKey.pageDown.usbHidUsage: 'PageDown',
  PhysicalKeyboardKey.insert.usbHidUsage: 'Insert',
  PhysicalKeyboardKey.delete.usbHidUsage: 'Delete',
};

/// A key with the modifiers held.
class KeyCombo {
  const KeyCombo(this.key, {this.ctrl = false, this.shift = false, this.alt = false});
  final int key;
  final bool ctrl, shift, alt;

  factory KeyCombo.ofEvent(KeyEvent e) {
    final k = HardwareKeyboard.instance;
    return KeyCombo(e.physicalKey.usbHidUsage, ctrl: k.isControlPressed, shift: k.isShiftPressed, alt: k.isAltPressed);
  }

  bool get isEscape => key == _escape;

  String get label => [if (ctrl) 'Ctrl', if (shift) 'Shift', if (alt) 'Alt', keyNames[key] ?? '?'].join('+');

  String get code => '${ctrl ? 1 : 0}${shift ? 1 : 0}${alt ? 1 : 0}:$key';

  static KeyCombo? parse(String code) {
    final m = RegExp(r'^([01])([01])([01]):(\d+)$').firstMatch(code);
    if (m == null) return null;
    return KeyCombo(int.parse(m[4]!), ctrl: m[1] == '1', shift: m[2] == '1', alt: m[3] == '1');
  }

  @override
  bool operator ==(Object other) => other is KeyCombo && other.code == code;
  @override
  int get hashCode => code.hashCode;
}

final Map<AppAction, KeyCombo?> defaultShortcuts = () {
  KeyCombo key(PhysicalKeyboardKey k, {bool ctrl = false, bool shift = false}) => KeyCombo(k.usbHidUsage, ctrl: ctrl, shift: shift);
  return {
    AppAction.playPause: key(PhysicalKeyboardKey.space),
    AppAction.playPause2: key(PhysicalKeyboardKey.keyK),
    AppAction.previous: key(PhysicalKeyboardKey.arrowLeft, ctrl: true),
    AppAction.next: key(PhysicalKeyboardKey.arrowRight, ctrl: true),
    AppAction.back: key(PhysicalKeyboardKey.keyJ),
    AppAction.forward: key(PhysicalKeyboardKey.keyL),
    AppAction.volumeUp: key(PhysicalKeyboardKey.arrowUp, ctrl: true),
    AppAction.volumeDown: key(PhysicalKeyboardKey.arrowDown, ctrl: true),
    AppAction.mute: key(PhysicalKeyboardKey.keyM),
    AppAction.lyrics: key(PhysicalKeyboardKey.keyC),
    AppAction.search: key(PhysicalKeyboardKey.slash),
    AppAction.filter: key(PhysicalKeyboardKey.keyF, ctrl: true),
    AppAction.selectAll: key(PhysicalKeyboardKey.keyA, ctrl: true),
    AppAction.nowPlaying: key(PhysicalKeyboardKey.keyJ, shift: true),
    AppAction.queue: key(PhysicalKeyboardKey.keyN, shift: true),
    AppAction.home: key(PhysicalKeyboardKey.keyH, shift: true),
    AppAction.settings: key(PhysicalKeyboardKey.keyP, ctrl: true),
    AppAction.help: key(PhysicalKeyboardKey.slash, ctrl: true),
  };
}();

/// The action on [combo], if any.
AppAction? actionFor(Map<AppAction, KeyCombo?> keys, KeyCombo combo) => keys.entries.where((e) => e.value == combo).firstOrNull?.key;

/// [keys] with [action] on [combo] (null: 未指定). A key does one thing, so
/// another action that had it loses it.
Map<AppAction, KeyCombo?> withShortcut(Map<AppAction, KeyCombo?> keys, AppAction action, KeyCombo? combo) => {
      for (final e in keys.entries) e.key: e.key == action ? combo : (e.value == combo ? null : e.value),
    };

/// Saved as {action: code or null}; an action not saved has its default.
Map<AppAction, KeyCombo?> decodeShortcuts(String? text) {
  final keys = {...defaultShortcuts};
  if (text == null) return keys;
  try {
    final saved = jsonDecode(text) as Map;
    for (final a in AppAction.values) {
      if (saved.containsKey(a.name)) {
        final code = saved[a.name];
        keys[a] = code is String ? KeyCombo.parse(code) : null;
      }
    }
  } catch (_) {}
  return keys;
}

String encodeShortcuts(Map<AppAction, KeyCombo?> keys) => jsonEncode({for (final e in keys.entries) e.key.name: e.value?.code});

class ShortcutsNotifier extends Notifier<Map<AppAction, KeyCombo?>> {
  @override
  Map<AppAction, KeyCombo?> build() {
    _load();
    return defaultShortcuts;
  }

  Future<void> _load() async => state = decodeShortcuts((await ref.read(dbProvider).allSettings())['shortcuts']);

  void set(AppAction action, KeyCombo? combo) {
    state = withShortcut(state, action, combo);
    ref.read(dbProvider).setSetting('shortcuts', encodeShortcuts(state));
  }

  void reset() {
    state = defaultShortcuts;
    ref.read(dbProvider).setSetting('shortcuts', encodeShortcuts(state));
  }
}

final shortcutsProvider = NotifierProvider<ShortcutsNotifier, Map<AppAction, KeyCombo?>>(ShortcutsNotifier.new);
