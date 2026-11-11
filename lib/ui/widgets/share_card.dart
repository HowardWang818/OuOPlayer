import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import 'art_image.dart';
import 'dialogs.dart';

/// 分享: a picture of the song (cover, title, artist, the cover's colour and
/// OuOPlayer's mark), tall for stories or square for posts and chats.
enum ShareShape {
  story('直式', 9 / 16),
  square('方形', 1);

  const ShareShape(this.label, this.aspect);
  final String label;
  final double aspect;
}

/// The card is laid out at this width and saved 4 times as large (1080 px).
const shareCardWidth = 270.0;
const shareScale = 4.0;
const shareCardRadius = 20.0;

Future<void> showShareCard(BuildContext context, Track track) => showDialog<void>(
      context: context,
      builder: (_) => _ShareDialog(track: track),
    );

class _ShareDialog extends ConsumerStatefulWidget {
  const _ShareDialog({required this.track});
  final Track track;

  @override
  ConsumerState<_ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends ConsumerState<_ShareDialog> {
  final _key = GlobalKey();
  ShareShape _shape = ShareShape.story;
  bool _busy = false;

  Future<void> _share() async {
    setState(() => _busy = true);
    try {
      final boundary = _key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: shareScale);
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
      final name = 'OuOPlayer_${widget.track.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}.png';
      if (Platform.isAndroid) {
        final dir = Directory(p.join((await getTemporaryDirectory()).path, 'share'));
        await dir.create(recursive: true);
        final file = File(p.join(dir.path, name));
        await file.writeAsBytes(png);
        await const MethodChannel('ouo/share').invokeMethod('image', {'path': file.path, 'text': '${widget.track.title} - ${widget.track.artist}'});
        if (mounted) Navigator.pop(context);
      } else {
        // Windows: saved to Pictures\OuOPlayer and shown in File Explorer.
        final dir = Directory(p.join(Platform.environment['USERPROFILE'] ?? '', 'Pictures', 'OuOPlayer'));
        await dir.create(recursive: true);
        final file = File(p.join(dir.path, name));
        await file.writeAsBytes(png);
        await Process.run('explorer.exe', ['/select,', file.path]);
        if (mounted) {
          toast(context, '圖片已儲存');
          Navigator.pop(context);
        }
      }
    } catch (e) {
      if (mounted) toast(context, '無法分享');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colour = ref.watch(artColorProvider(widget.track.art)).value ?? const Color(0xFF2A3A55);
    return AlertDialog(
      title: const Text('分享歌曲'),
      contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        SegmentedButton<ShareShape>(
          segments: [for (final s in ShareShape.values) ButtonSegment(value: s, label: Text(s.label))],
          selected: {_shape},
          onSelectionChanged: (v) => setState(() => _shape = v.first),
        ),
        const SizedBox(height: 12),
        // Scaled to fit the dialog; captured at its own size.
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 400),
          child: FittedBox(
            child: RepaintBoundary(
              key: _key,
              child: ShareCard(track: widget.track, shape: _shape, colour: colour),
            ),
          ),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton.icon(
          onPressed: _busy ? null : _share,
          icon: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(Platform.isAndroid ? Icons.share : Icons.save_alt),
          label: Text(Platform.isAndroid ? '分享' : '儲存圖片'),
        ),
      ],
    );
  }
}

/// The picture itself, [shareCardWidth] wide.
class ShareCard extends StatelessWidget {
  const ShareCard({super.key, required this.track, required this.shape, required this.colour});
  final Track track;
  final ShareShape shape;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    final tall = shape == ShareShape.story;
    final h = shareCardWidth / shape.aspect;
    final dark = Color.lerp(colour, Colors.black, 0.75)!;
    // Fixed rounded corners in both shapes (transparent outside them).
    return SizedBox(
      width: shareCardWidth,
      height: h,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(shareCardRadius),
        child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [colour, dark]),
        ),
        child: Padding(
          padding: EdgeInsets.all(tall ? 24 : 20),
          child: DefaultTextStyle(
            style: const TextStyle(color: Colors.white, decoration: TextDecoration.none, fontWeight: FontWeight.normal),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (tall) const Spacer(),
              Center(
                child: Container(
                  decoration: BoxDecoration(boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 16, offset: const Offset(0, 6))]),
                  child: ArtImage(track.art, size: tall ? 200 : 130, radius: 10),
                ),
              ),
              SizedBox(height: tall ? 24 : 14),
              Text(track.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: tall ? 20 : 16, fontWeight: FontWeight.w700, height: 1.2)),
              const SizedBox(height: 4),
              Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: tall ? 14 : 12, color: Colors.white.withValues(alpha: 0.8))),
              const Spacer(),
              Row(children: [
                ClipRRect(borderRadius: BorderRadius.circular(4), child: Image.asset('assets/icon/app_icon_dark.png', width: 18, height: 18)),
                const SizedBox(width: 6),
                Text('Listen on OuOPlayer', style: TextStyle(fontSize: 10, color: Colors.white.withValues(alpha: 0.85))),
              ]),
            ]),
          ),
        ),
        ),
      ),
    );
  }
}
