import 'package:dio/dio.dart';

/// A YouTube video found for a song.
class YouTubeVideo {
  final String id;
  final String title;
  final String channel;
  const YouTubeVideo(this.id, this.title, this.channel);

  String get url => 'https://www.youtube.com/watch?v=$id';
}

/// A failure explained in plain Traditional Chinese for the UI.
class YouTubeLinkException implements Exception {
  final String message;
  const YouTubeLinkException(this.message);
  @override
  String toString() => message;
}

/// Finds a song's video with the official YouTube Data API v3. Only returns a
/// link; nothing is played or downloaded here.
class YouTubeLinkFinder {
  YouTubeLinkFinder({Dio? dio}) : _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 10), receiveTimeout: const Duration(seconds: 15)));

  final Dio _dio;

  Future<YouTubeVideo?> find(String apiKey, String query) async {
    if (apiKey.trim().isEmpty) throw const YouTubeLinkException('尚未設定 YouTube Data API 金鑰');
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        'https://www.googleapis.com/youtube/v3/search',
        queryParameters: {'part': 'snippet', 'type': 'video', 'maxResults': 1, 'q': query, 'key': apiKey.trim()},
      );
      return parse(res.data ?? const {});
    } on DioException catch (e) {
      throw YouTubeLinkException(explainError(e.response?.data, e.message));
    }
  }

  /// Runs one real search so the guide page can confirm the key works.
  Future<void> testKey(String apiKey) async {
    await find(apiKey, 'OuOPlayer test');
  }

  static YouTubeVideo? parse(Map<String, dynamic> body) {
    final items = body['items'] as List? ?? const [];
    for (final item in items.cast<Map<String, dynamic>>()) {
      final id = (item['id'] as Map?)?['videoId'] as String?;
      if (id == null) continue;
      final snippet = item['snippet'] as Map? ?? const {};
      return YouTubeVideo(id, snippet['title'] as String? ?? '', snippet['channelTitle'] as String? ?? '');
    }
    return null;
  }

  /// Turns Google's error payload into an actionable message.
  static String explainError(Object? data, String? fallback) {
    final error = data is Map ? data['error'] : null;
    final errors = error is Map ? error['errors'] : null;
    final reason = errors is List && errors.isNotEmpty && errors.first is Map ? (errors.first as Map)['reason'] as String? : null;
    final message = error is Map ? error['message'] as String? ?? '' : '';
    switch (reason) {
      case 'quotaExceeded':
      case 'dailyLimitExceeded':
        return '今日的免費額度已用完，明天會自動恢復';
      case 'keyInvalid':
        return '金鑰無效，請確認是否完整複製';
      case 'accessNotConfigured':
      case 'SERVICE_DISABLED':
        return '這個專案尚未啟用 YouTube Data API v3';
      case 'forbidden':
      case 'ipRefererBlocked':
        return '金鑰的使用限制擋住了這個請求，請檢查金鑰的 API 限制設定';
    }
    if (message.contains('API key not valid')) return '金鑰無效，請確認是否完整複製';
    if (message.contains('has not been used') || message.contains('is disabled')) return '這個專案尚未啟用 YouTube Data API v3';
    if (data == null) return '無法連線到 YouTube，請檢查網路';
    return message.isNotEmpty ? message : (fallback ?? '查詢失敗');
  }
}
