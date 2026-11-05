import 'package:flutter/material.dart';

import 'art_image.dart';

/// 外觀 → 封面 → 黑膠: the cover as a record, turning once every 20 seconds
/// while [playing] and standing still where it is when paused.
class VinylCover extends StatefulWidget {
  const VinylCover({super.key, required this.art, required this.size, required this.playing});
  final String? art;
  final double size;
  final bool playing;

  @override
  State<VinylCover> createState() => _VinylCoverState();
}

class _VinylCoverState extends State<VinylCover> with SingleTickerProviderStateMixin {
  late final _turn = AnimationController(vsync: this, duration: const Duration(seconds: 20));

  @override
  void initState() {
    super.initState();
    if (widget.playing) _turn.repeat();
  }

  @override
  void didUpdateWidget(VinylCover old) {
    super.didUpdateWidget(old);
    if (widget.playing && !_turn.isAnimating) {
      _turn.repeat();
    } else if (!widget.playing && _turn.isAnimating) {
      _turn.stop();
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final hole = Theme.of(context).scaffoldBackgroundColor;
    return RotationTransition(
      turns: _turn,
      child: Stack(alignment: Alignment.center, children: [
        // The record's black rim, then the cover as its label.
        Container(width: s, height: s, decoration: const BoxDecoration(color: Color(0xFF111111), shape: BoxShape.circle)),
        ArtImage(widget.art, size: s * 0.94, circle: true),
        // Grooves: a few faint rings over the cover.
        for (final f in const [0.62, 0.74, 0.86])
          Container(
            width: s * f,
            height: s * f,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.black.withValues(alpha: 0.18), width: 1)),
          ),
        Container(
          width: s * 0.16,
          height: s * 0.16,
          decoration: BoxDecoration(color: const Color(0xFF111111), shape: BoxShape.circle, border: Border.all(color: Colors.white24, width: 1)),
        ),
        Container(width: s * 0.045, height: s * 0.045, decoration: BoxDecoration(color: hole, shape: BoxShape.circle)),
      ]),
    );
  }
}
