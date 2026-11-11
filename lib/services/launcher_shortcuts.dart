import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The long-press shortcuts on the home-screen icon, in the app's own icons.
const launcherShortcutIcons = <String, IconData>{
  'shuffle': Icons.shuffle_rounded,
  'resume': Icons.play_arrow_rounded,
  'search': Icons.search_rounded,
};

/// Adaptive icons are 108 dp with the middle 72 dp always visible; drawn at
/// 4x (432 px) like the launcher's own.
const shortcutIconSize = 432;

/// One shortcut icon: [icon] in [fg] on a full-bleed [bg] (the launcher cuts
/// it to its shape). PNG bytes.
Future<Uint8List> drawShortcutIcon(IconData icon, Color bg, Color fg) async {
  const size = 432.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, size, size), Paint()..color = bg);
  final glyph = TextPainter(
    text: TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(fontFamily: icon.fontFamily, package: icon.fontPackage, fontSize: 168, color: fg, height: 1),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  glyph.paint(canvas, Offset((size - glyph.width) / 2, (size - glyph.height) / 2));
  final image = await recorder.endRecording().toImage(shortcutIconSize, shortcutIconSize);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}
