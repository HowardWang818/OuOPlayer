import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/services/player_widget.dart';

void main() {
  test('widget text stays readable on the cover colour', () {
    expect(widgetForeground(const Color(0xFF1B2A4A)), Colors.white);
    expect(widgetForeground(const Color(0xFF181818)), Colors.white);
    expect(widgetForeground(const Color(0xFFF2E6B0)), Colors.black87);
    expect(widgetForeground(Colors.white), Colors.black87);
  });
}
