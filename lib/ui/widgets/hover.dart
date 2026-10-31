import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Rebuilds with whether the mouse is over [builder]'s widget.
class Hover extends StatefulWidget {
  const Hover({super.key, required this.builder});
  final Widget Function(BuildContext context, bool hovering) builder;

  @override
  State<Hover> createState() => _HoverState();
}

class _HoverState extends State<Hover> {
  bool _on = false;

  void _set(bool on) {
    if (on != _on) setState(() => _on = on);
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => _set(true),
        onExit: (_) => _set(false),
        child: widget.builder(context, _on),
      );
}

/// A little bigger under the mouse (buttons with a size of their own, which
/// the theme's hover size can't reach).
class HoverBump extends StatelessWidget {
  const HoverBump({super.key, required this.child, this.scale = 1.1});
  final Widget child;
  final double scale;

  @override
  Widget build(BuildContext context) => Hover(
        builder: (_, on) => AnimatedScale(scale: on ? scale : 1, duration: const Duration(milliseconds: 100), child: child),
      );
}

/// One line that scrolls when it doesn't fit: all the time ([auto]) or under
/// the mouse. [still] is shown while it isn't scrolling (cut off with …).
class Marquee extends StatefulWidget {
  const Marquee({super.key, required this.child, this.still, this.auto = false});
  final Widget child;
  final Widget? still;
  final bool auto;

  @override
  State<Marquee> createState() => _MarqueeState();
}

class _MarqueeState extends State<Marquee> {
  final _scroll = ScrollController();
  bool _on = false, _running = false;

  static const _speed = 30.0; // pixels a second
  static const _pause = Duration(seconds: 2);

  bool get _go => mounted && (_on || widget.auto) && _scroll.hasClients;

  Future<void> _run() async {
    if (_running) return;
    _running = true;
    await WidgetsBinding.instance.endOfFrame;
    while (_go) {
      await Future.delayed(_pause);
      if (!_go) break;
      final end = _scroll.position.maxScrollExtent;
      // It fits now; on the next song it may not.
      if (end <= 0) {
        if (widget.auto) continue;
        break;
      }
      await _scroll.animateTo(end, duration: Duration(milliseconds: (end / _speed * 1000).round()), curve: Curves.linear);
      await Future.delayed(_pause);
      if (!_go) break;
      await _scroll.animateTo(0, duration: const Duration(milliseconds: 900), curve: Curves.easeInOut);
    }
    _running = false;
  }

  void _set(bool on) {
    if (on == _on || widget.auto) return;
    setState(() => _on = on);
    if (on) _run();
  }

  @override
  void initState() {
    super.initState();
    if (widget.auto) _run();
  }

  @override
  void didUpdateWidget(Marquee old) {
    super.didUpdateWidget(old);
    // Another song starts from the beginning.
    if (widget.auto && _scroll.hasClients && _scroll.offset > 0 && old.child.key != widget.child.key) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    _on = false;
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => _set(true),
        onExit: (_) => _set(false),
        child: _on || widget.auto
            ? SingleChildScrollView(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                child: widget.child,
              )
            : widget.still ?? widget.child,
      );
}

/// The strip between two panels: dragged to resize them. The new size comes
/// from where the mouse is now against where the drag began, so it stays
/// under the mouse.
class PanelDivider extends StatefulWidget {
  const PanelDivider({super.key, required this.value, required this.onDrag, required this.onEnd, this.vertical = false, this.reversed = false});

  /// The size being changed, when the drag begins.
  final double value;
  final void Function(double size) onDrag;
  final VoidCallback onEnd;

  /// Between a top and a bottom panel.
  final bool vertical;

  /// The panel is on the far side (dragging towards it makes it smaller).
  final bool reversed;

  @override
  State<PanelDivider> createState() => _PanelDividerState();
}

class _PanelDividerState extends State<PanelDivider> {
  double _from = 0, _size = 0;

  void _start(DragStartDetails d) {
    _from = widget.vertical ? d.globalPosition.dy : d.globalPosition.dx;
    _size = widget.value;
  }

  void _update(DragUpdateDetails d) {
    final moved = (widget.vertical ? d.globalPosition.dy : d.globalPosition.dx) - _from;
    widget.onDrag(_size + (widget.reversed ? -moved : moved));
  }

  @override
  Widget build(BuildContext context) {
    final vertical = widget.vertical;
    return MouseRegion(
      cursor: vertical ? SystemMouseCursors.resizeRow : SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragStart: vertical ? null : _start,
        onHorizontalDragUpdate: vertical ? null : _update,
        onHorizontalDragEnd: vertical ? null : (_) => widget.onEnd(),
        onVerticalDragStart: vertical ? _start : null,
        onVerticalDragUpdate: vertical ? _update : null,
        onVerticalDragEnd: vertical ? (_) => widget.onEnd() : null,
        child: SizedBox(width: vertical ? double.infinity : 8, height: vertical ? 8 : null),
      ),
    );
  }
}
