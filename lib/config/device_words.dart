import 'dart:io';

/// 「手機」 or 「電腦」 in messages shown on both platforms (「電腦上還沒有這首歌」).
String get thisDevice => Platform.isAndroid ? '手機' : '電腦';
