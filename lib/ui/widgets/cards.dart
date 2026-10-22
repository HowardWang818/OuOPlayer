import 'package:flutter/material.dart';

import 'art_image.dart';

/// Square cover + title + subtitle card used in horizontal shelves and grids.
class CoverCard extends StatelessWidget {
  const CoverCard({super.key, required this.art, required this.title, this.subtitle = '', required this.onTap, this.circle = false, this.size = 150, this.icon = Icons.album});

  final String? art;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool circle;
  final double size;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: SizedBox(
          width: size,
          child: Column(crossAxisAlignment: circle ? CrossAxisAlignment.center : CrossAxisAlignment.start, children: [
            ArtImage(art, size: size, radius: 6, circle: circle, icon: icon),
            const SizedBox(height: 8),
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (subtitle.isNotEmpty) Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: muted)),
          ]),
        ),
      ),
    );
  }
}

class Shelf extends StatelessWidget {
  const Shelf({super.key, required this.title, required this.children, this.height = 220});
  final String title;
  final List<Widget> children;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
      ),
      SizedBox(
        height: height,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: children),
      ),
    ]);
  }
}

/// Compact tile used in the "quick picks" grid at the top of Home.
class QuickTile extends StatelessWidget {
  const QuickTile({super.key, required this.leading, required this.title, required this.onTap});
  final Widget leading;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(4),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Row(children: [
          SizedBox(width: 56, height: 56, child: leading),
          const SizedBox(width: 10),
          Expanded(child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
        ]),
      ),
    );
  }
}
