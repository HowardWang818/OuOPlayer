import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../../theme/app_theme.dart';
import '../pages/devices_page.dart';

IconData outputIcon(String kind) => switch (kind) {
      'bluetooth' => Icons.bluetooth_audio,
      'wired' => Icons.headphones,
      'usb' => Icons.usb,
      'speaker' => Icons.speaker,
      _ => Icons.devices_other,
    };

/// "正在透過 XXX 播放" — like the Spotify Connect bar. Android only.
class OutputDeviceChip extends ConsumerWidget {
  const OutputDeviceChip({super.key, this.dense = false, this.color});
  final bool dense;

  /// Overrides the icon/text colour (e.g. on the accent-coloured mini player).
  final Color? color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(bluetoothProvider).supported) return const SizedBox.shrink();
    final dev = ref.watch(outputDeviceProvider).value;
    if (dev == null) return const SizedBox.shrink();
    final external = dev.kind != 'speaker';
    final color = this.color ?? (external ? AppColors.accent : Theme.of(context).colorScheme.onSurfaceVariant);
    void open() => Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => const DevicesPage()));
    if (dense) {
      return IconButton(icon: Icon(outputIcon(dev.kind), color: color, size: 20), tooltip: dev.name, onPressed: open);
    }
    return InkWell(
      onTap: open,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(outputIcon(dev.kind), size: 16, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(external ? '正在透過 ${dev.name} 播放' : dev.name,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
          ),
        ]),
      ),
    );
  }
}
