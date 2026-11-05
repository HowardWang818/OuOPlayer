import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// 外觀 → 背景 → 模糊封面: the cover, blurred, under a veil of the page
/// colour. Always laid out the size of the whole window and moved up by
/// [offset] (how far down the window this piece starts), so the Windows title
/// bar and the player page below it draw the same picture and meet without a
/// seam.
class BlurredCover extends StatelessWidget {
  const BlurredCover({super.key, required this.art, required this.veil, this.offset = 0});
  final String art;
  final Color veil;
  final double offset;

  @override
  Widget build(BuildContext context) {
    final window = MediaQuery.sizeOf(context);
    final image = art.startsWith('http')
        ? Image.network(art, fit: BoxFit.cover, cacheWidth: 300, errorBuilder: (_, __, ___) => const SizedBox())
        : Image.file(File(art), fit: BoxFit.cover, cacheWidth: 300, errorBuilder: (_, __, ___) => const SizedBox());
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: window.width,
        maxWidth: window.width,
        minHeight: window.height,
        maxHeight: window.height,
        child: Transform.translate(
          offset: Offset(0, -offset),
          child: Stack(fit: StackFit.expand, children: [
            ImageFiltered(imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40, tileMode: TileMode.clamp), child: image),
            ColoredBox(color: veil),
          ]),
        ),
      ),
    );
  }
}
