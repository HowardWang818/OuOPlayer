import 'package:flutter/material.dart';

import '../../services/download_service.dart';
import 'art_image.dart';

/// A cover with the download's state on it: a ring while it downloads, a
/// tick when done, a mark when it failed. Just the cover without [task].
class CoverProgress extends StatelessWidget {
  const CoverProgress({super.key, required this.art, this.task, this.size = 48});
  final String? art;
  final DownloadTask? task;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = task;
    final cover = ArtImage(art ?? t?.art, size: size);
    if (t == null || t.status == DownloadStatus.cancelled) return cover;
    final Widget mark = switch (t.status) {
      DownloadStatus.queued || DownloadStatus.running => SizedBox(
          width: size * 0.55,
          height: size * 0.55,
          child: CircularProgressIndicator(
            value: t.status == DownloadStatus.running && t.progress > 0 ? t.progress : null,
            strokeWidth: 3,
            color: Colors.white,
            backgroundColor: Colors.white24,
          ),
        ),
      DownloadStatus.done => Icon(Icons.check_rounded, color: Colors.white, size: size * 0.5),
      _ => Icon(Icons.error_outline_rounded, color: Colors.white, size: size * 0.5),
    };
    return SizedBox(
      width: size,
      height: size,
      child: Stack(alignment: Alignment.center, children: [
        cover,
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(4)),
          ),
        ),
        mark,
      ]),
    );
  }
}
