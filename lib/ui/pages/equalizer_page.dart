import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../../services/equalizer.dart';
import '../../theme/app_theme.dart';

/// 等化器: on/off, presets and five sliders (moving one switches to 自訂).
class EqualizerPage extends ConsumerWidget {
  const EqualizerPage({super.key});

  static String _hz(int f) => f >= 1000 ? '${(f / 1000).toStringAsFixed(f % 1000 == 0 ? 0 : 1)}k' : '$f';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final preset = EqPreset.byName(s.eqPreset);
    final gains = eqGains(preset, s.eqCustom);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: const Text('等化器')),
      body: ListView(children: [
        SwitchListTile(
          title: const Text('啟用等化器'),
          subtitle: const Text('可以和音量平衡一起使用'),
          value: s.eqEnabled,
          onChanged: n.setEqEnabled,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final p in EqPreset.values)
              ChoiceChip(
                label: Text(p.label),
                selected: p == preset,
                showCheckmark: false,
                onSelected: s.eqEnabled ? (_) => n.setEqPreset(p.name) : null,
              ),
          ]),
        ),
        Opacity(
          opacity: s.eqEnabled ? 1 : 0.4,
          child: SizedBox(
            height: 300,
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              for (var i = 0; i < eqFrequencies.length; i++)
                Column(children: [
                  Text('${gains[i] > 0 ? '+' : ''}${gains[i].toStringAsFixed(0)} dB', style: TextStyle(fontSize: 12, color: muted)),
                  Expanded(
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: Slider(
                        min: -eqMaxDb,
                        max: eqMaxDb,
                        divisions: 24,
                        activeColor: AppColors.accent,
                        value: gains[i].clamp(-eqMaxDb, eqMaxDb),
                        onChanged: s.eqEnabled ? (v) => n.setEqCustom([...gains]..[i] = v.roundToDouble()) : null,
                      ),
                    ),
                  ),
                  Text('${_hz(eqFrequencies[i])} Hz', style: TextStyle(fontSize: 12, color: muted)),
                ]),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Android 會依手機支援的頻段套用，效果可能因手機和耳機而略有不同。', style: TextStyle(fontSize: 12, color: muted)),
        ),
      ]),
    );
  }
}
