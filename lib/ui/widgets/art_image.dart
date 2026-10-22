import 'dart:io';

import 'package:flutter/material.dart';

class ArtImage extends StatelessWidget {
  const ArtImage(this.art, {super.key, this.size = 48, this.radius = 4, this.icon = Icons.music_note, this.circle = false});

  final String? art;
  final double size;
  final double radius;
  final IconData icon;
  final bool circle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: size,
      height: size,
      color: cs.surfaceContainerHigh,
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.45, color: cs.onSurfaceVariant),
    );
    Widget child = placeholder;
    final a = art;
    if (a != null && a.isNotEmpty) {
      final cache = (size * MediaQuery.devicePixelRatioOf(context)).round();
      child = a.startsWith('http')
          ? Image.network(a, width: size, height: size, fit: BoxFit.cover, cacheWidth: cache, errorBuilder: (_, __, ___) => placeholder)
          : Image.file(File(a), width: size, height: size, fit: BoxFit.cover, cacheWidth: cache, errorBuilder: (_, __, ___) => placeholder);
    }
    return circle ? ClipOval(child: child) : ClipRRect(borderRadius: BorderRadius.circular(radius), child: child);
  }
}

String formatDuration(Duration? d) {
  if (d == null) return '--:--';
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(h > 0 ? 2 : 1, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}
