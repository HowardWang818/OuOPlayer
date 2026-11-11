import 'dart:convert';

/// Which playlist downloaded songs go into: asked once, then used without
/// asking for an hour (so a run of downloads isn't interrupted).
class DownloadTarget {
  const DownloadTarget({this.playlistId, this.name, required this.at});

  /// Null: only into the library.
  final int? playlistId;
  final String? name;
  final DateTime at;

  static const key = 'download_target';
  static const remember = Duration(hours: 1);

  /// Still within the hour after it was picked.
  bool freshAt(DateTime now) => now.difference(at) < remember;

  String encode() => jsonEncode({'id': playlistId, 'name': name, 'at': at.millisecondsSinceEpoch});

  static DownloadTarget? decode(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final m = jsonDecode(s) as Map;
      return DownloadTarget(
        playlistId: (m['id'] as num?)?.toInt(),
        name: m['name'] as String?,
        at: DateTime.fromMillisecondsSinceEpoch((m['at'] as num).toInt()),
      );
    } catch (_) {
      return null;
    }
  }
}
