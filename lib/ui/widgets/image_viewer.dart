import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Makes [child] (a big cover or photo) open [art] full screen on tap.
/// Nothing happens when there is no picture.
class ZoomableArt extends StatelessWidget {
  const ZoomableArt({super.key, required this.art, required this.child, this.circle = false});
  final String? art;
  final Widget child;
  final bool circle;

  @override
  Widget build(BuildContext context) {
    final a = art;
    if (a == null || a.isEmpty) return child;
    return GestureDetector(
      onTap: () => showImageViewer(context, a, tag: ('zoom', a)),
      child: Hero(tag: ('zoom', a), child: child),
    );
  }
}

/// Full-screen picture: pinch or double-tap to zoom (mouse wheel on Windows),
/// swipe down, back or Esc to close.
Future<void> showImageViewer(BuildContext context, String art, {Object? tag}) => Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder(
        opaque: false,
        transitionDuration: const Duration(milliseconds: 250),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (_, __, ___) => _ImageViewer(art: art, tag: tag),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(opacity: anim, child: child),
      ),
    );

class _ImageViewer extends StatefulWidget {
  const _ImageViewer({required this.art, this.tag});
  final String art;
  final Object? tag;

  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewer> {
  final _zoom = TransformationController();
  TapDownDetails? _doubleTap;
  double _drag = 0;

  bool get _zoomed => _zoom.value.getMaxScaleOnAxis() > 1.01;

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  void _toggleZoom() {
    if (_zoomed) {
      _zoom.value = Matrix4.identity();
      return;
    }
    final p = _doubleTap?.localPosition ?? Offset.zero;
    _zoom.value = Matrix4.identity()
      ..translateByDouble(-p.dx * 1.5, -p.dy * 1.5, 0, 1)
      ..scaleByDouble(2.5, 2.5, 1, 1);
  }

  void _wheel(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final s = _zoom.value.getMaxScaleOnAxis();
    final next = (s * (e.scrollDelta.dy > 0 ? 0.85 : 1.18)).clamp(1.0, 5.0);
    if (next == 1.0) {
      _zoom.value = Matrix4.identity();
      return;
    }
    final f = next / s;
    final p = e.localPosition;
    _zoom.value = Matrix4.identity()
      ..translateByDouble(p.dx * (1 - f), p.dy * (1 - f), 0, 1)
      ..scaleByDouble(f, f, 1, 1)
      ..multiply(_zoom.value);
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.art;
    final image = a.startsWith('http') ? Image.network(a, fit: BoxFit.contain) : Image.file(File(a), fit: BoxFit.contain);
    final shown = widget.tag == null ? image : Hero(tag: widget.tag!, child: image);
    final fade = (1 - _drag.abs() / 400).clamp(0.3, 1.0);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.pop(context)},
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black.withValues(alpha: fade),
          body: Stack(children: [
            Listener(
              onPointerSignal: _wheel,
              child: GestureDetector(
                onDoubleTapDown: (d) => _doubleTap = d,
                onDoubleTap: _toggleZoom,
                child: Transform.translate(
                  offset: Offset(0, _drag),
                  child: InteractiveViewer(
                    transformationController: _zoom,
                    minScale: 1,
                    maxScale: 5,
                    // Not zoomed in: one finger up or down drags the picture away.
                    onInteractionUpdate: (d) {
                      if (!_zoomed && d.pointerCount == 1) setState(() => _drag += d.focalPointDelta.dy);
                    },
                    onInteractionEnd: (d) {
                      if (!_zoomed && (_drag.abs() > 120 || d.velocity.pixelsPerSecond.dy.abs() > 800)) {
                        Navigator.pop(context);
                      } else {
                        setState(() => _drag = 0);
                      }
                    },
                    child: SizedBox.expand(child: Center(child: shown)),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Align(
                alignment: Alignment.topLeft,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  tooltip: '關閉',
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
