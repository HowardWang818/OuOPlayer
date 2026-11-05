import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/looks.dart';
import '../theme/themes.dart';
import 'providers.dart';

/// The colour theme (設定 → 外觀 → 主題): a preset's id or 'custom' with its
/// colour. [at] is when it was chosen, so sync can tell which device chose last.
class ThemeChoice {
  const ThemeChoice(this.id, {this.custom, this.at = 0});
  final String id;
  final Color? custom;
  final int at;

  ColorTheme get theme => ColorTheme.byId(id, custom: custom);

  static ThemeChoice fromSettings(Map<String, String> s) {
    final c = int.tryParse(s['color_theme_custom'] ?? '', radix: 16);
    return ThemeChoice(s['color_theme'] ?? ColorTheme.defaultId,
        custom: c == null ? null : Color(c), at: int.tryParse(s['color_theme_at'] ?? '') ?? 0);
  }

  /// As a sync file has it.
  Map<String, Object?> toJson() => {'id': id, if (custom != null) 'c': custom!.toARGB32().toRadixString(16), 'at': at};

  static ThemeChoice? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String) return null;
    final c = int.tryParse('${j['c'] ?? ''}', radix: 16);
    return ThemeChoice(j['id'] as String, custom: c == null ? null : Color(c), at: (j['at'] as num?)?.toInt() ?? 0);
  }
}

/// The theme saved when the app started (main.dart), so the first frame is
/// already in its colours.
final initialThemeChoiceProvider = Provider<ThemeChoice>((ref) => const ThemeChoice(ColorTheme.defaultId));

class ThemeChoiceNotifier extends Notifier<ThemeChoice> {
  @override
  ThemeChoice build() => ref.read(initialThemeChoiceProvider);

  Future<void> _load() async => state = ThemeChoice.fromSettings(await ref.read(dbProvider).allSettings());

  /// Chosen here (now).
  Future<void> choose(String id, {Color? custom}) =>
      apply(ThemeChoice(id, custom: custom ?? (id == 'custom' ? state.custom : null), at: DateTime.now().millisecondsSinceEpoch));

  /// Saves [c] as it is (also what sync brought in).
  Future<void> apply(ThemeChoice c) async {
    state = c;
    final db = ref.read(dbProvider);
    await db.setSetting('color_theme', c.id);
    if (c.custom != null) await db.setSetting('color_theme_custom', c.custom!.toARGB32().toRadixString(16));
    await db.setSetting('color_theme_at', '${c.at}');
  }

  /// Settings changed under it (a restored backup, sync).
  Future<void> reload() => _load();
}

final themeChoiceProvider = NotifierProvider<ThemeChoiceNotifier, ThemeChoice>(ThemeChoiceNotifier.new);

/// The 外觀 choices saved when the app started (main.dart).
final initialLooksProvider = Provider<Looks>((ref) => const Looks());

/// 外觀: player background, cover, lyrics, list density, corners, pure black.
class LooksNotifier extends Notifier<Looks> {
  @override
  Looks build() => ref.read(initialLooksProvider);

  /// Saves [l]; synced with the colour theme, so its time moves too.
  Future<void> set(Looks l) async {
    state = l;
    final db = ref.read(dbProvider);
    for (final e in l.toSettings().entries) {
      await db.setSetting(e.key, e.value);
    }
    await db.setSetting('color_theme_at', '${DateTime.now().millisecondsSinceEpoch}');
  }

  /// Settings changed under it (a restored backup, sync).
  Future<void> reload() async => state = Looks.fromSettings(await ref.read(dbProvider).allSettings());
}

final looksProvider = NotifierProvider<LooksNotifier, Looks>(LooksNotifier.new);
