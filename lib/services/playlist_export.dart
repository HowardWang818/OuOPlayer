import 'dart:convert';
import 'dart:typed_data';

import '../data/models/track.dart';

/// Formats a playlist can be copied or exported as.
enum ExportFormat {
  text('文字', 'txt', 'text/plain'),
  csv('CSV（Excel、試算表）', 'csv', 'text/csv'),
  m3u8('M3U8 播放清單（其他播放器）', 'm3u8', 'audio/x-mpegurl');

  const ExportFormat(this.label, this.extension, this.mimeType);
  final String label;
  final String extension;
  final String mimeType;
}

/// Turns a list of songs into text for the clipboard or an export file.
class PlaylistExport {
  const PlaylistExport(this.name, this.tracks);

  final String name;
  final List<Track> tracks;

  /// 「名稱（N 首）」 then one numbered 「歌名 - 歌手」 line per song.
  String text() => [
        '$name（${tracks.length} 首）',
        for (var i = 0; i < tracks.length; i++) '${i + 1}. ${tracks[i].title} - ${tracks[i].artist}',
      ].join('\n');

  String csv() => [
        '編號,歌名,歌手,專輯,長度',
        for (var i = 0; i < tracks.length; i++)
          [
            '${i + 1}',
            tracks[i].title,
            tracks[i].artist,
            tracks[i].album,
            _duration(tracks[i].durationMs),
          ].map(_csvField).join(','),
      ].join('\r\n');

  /// Extended M3U with UTF-8 paths (or URLs for online songs).
  String m3u8() => [
        '#EXTM3U',
        '#PLAYLIST:$name',
        for (final t in tracks) ...[
          '#EXTINF:${t.durationMs == null ? -1 : (t.durationMs! / 1000).round()},${t.artist} - ${t.title}',
          t.uri,
        ],
      ].join('\n');

  String content(ExportFormat f) => switch (f) {
        ExportFormat.text => text(),
        ExportFormat.csv => csv(),
        ExportFormat.m3u8 => m3u8(),
      };

  /// File bytes; CSV gets a UTF-8 BOM so Excel shows Japanese and Chinese.
  Uint8List bytes(ExportFormat f) =>
      Uint8List.fromList([if (f == ExportFormat.csv) ...[0xEF, 0xBB, 0xBF], ...utf8.encode(content(f))]);

  /// The playlist name made safe as a file name.
  String fileName(ExportFormat f) {
    final safe = name.replaceAll(RegExp(r'[\/:*?"<>|\n\r]'), '_').trim();
    return '${safe.isEmpty ? '播放清單' : safe}.${f.extension}';
  }

  static String _duration(int? ms) {
    if (ms == null) return '';
    final s = (ms / 1000).round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  static String _csvField(String v) =>
      v.contains(RegExp(r'[",\r\n]')) ? '"${v.replaceAll('"', '""')}"' : v;
}
