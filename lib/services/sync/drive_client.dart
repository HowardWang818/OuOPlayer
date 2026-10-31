import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'google_auth.dart';

/// A file in the app's hidden Drive folder.
class DriveFile {
  const DriveFile(this.id, this.name, this.modified);
  final String id;
  final String name;
  final DateTime modified;
}

/// What sync needs from Google Drive (tests use an in-memory one).
abstract interface class DriveStore {
  Future<List<DriveFile>> list();
  Future<Uint8List> download(String id);
  Future<String> upload(String name, List<int> bytes, {String? id, String mime});
  Future<String> uploadFile(String name, File file, {String mime, void Function(int, int)? onProgress, CancelToken? cancel});
  Future<void> downloadTo(String id, String path, {void Function(int, int)? onProgress, CancelToken? cancel});
  Future<void> delete(String id);
}

/// The Drive REST calls sync needs, all inside appDataFolder.
class DriveClient implements DriveStore {
  DriveClient(this._auth);
  final GoogleAuth _auth;
  final _dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 20), receiveTimeout: const Duration(minutes: 5)));
  static const _api = 'https://www.googleapis.com/drive/v3';
  static const _upload = 'https://www.googleapis.com/upload/drive/v3';

  /// Runs [call] with a token, once more with a fresh one if it was refused.
  Future<T> _authed<T>(Future<T> Function(Options o) call) async {
    for (var attempt = 0;; attempt++) {
      final token = await _auth.token();
      if (token == null) throw const SignedOut();
      try {
        return await call(Options(headers: {'Authorization': 'Bearer $token'}));
      } on DioException catch (e) {
        if (e.response?.statusCode == 401 && attempt == 0) {
          await _auth.invalidate(token);
          continue;
        }
        rethrow;
      }
    }
  }

  @override
  Future<List<DriveFile>> list() => _authed((o) async {
        final files = <DriveFile>[];
        String? page;
        do {
          final res = await _dio.get<Map<String, dynamic>>('$_api/files',
              queryParameters: {
                'spaces': 'appDataFolder',
                'fields': 'nextPageToken,files(id,name,modifiedTime)',
                'pageSize': 1000,
                if (page != null) 'pageToken': page,
              },
              options: o);
          for (final f in (res.data!['files'] as List).cast<Map>()) {
            files.add(DriveFile(f['id'] as String, f['name'] as String, DateTime.parse(f['modifiedTime'] as String)));
          }
          page = res.data!['nextPageToken'] as String?;
        } while (page != null);
        return files;
      });

  @override
  Future<Uint8List> download(String id) => _authed((o) async {
        final res = await _dio.get<List<int>>('$_api/files/$id',
            queryParameters: {'alt': 'media'}, options: o.copyWith(responseType: ResponseType.bytes));
        return Uint8List.fromList(res.data!);
      });

  /// Creates [name] (or replaces file [id]) with [bytes].
  @override
  Future<String> upload(String name, List<int> bytes, {String? id, String mime = 'application/octet-stream'}) => _authed((o) async {
        if (id != null) {
          await _dio.patch('$_upload/files/$id',
              queryParameters: {'uploadType': 'media'},
              data: Stream.fromIterable([bytes]),
              options: o.copyWith(headers: {...?o.headers, 'Content-Type': mime, 'Content-Length': bytes.length}));
          return id;
        }
        const boundary = 'ouoplayer-sync-boundary';
        final meta = jsonEncode({'name': name, 'parents': ['appDataFolder']});
        final body = <int>[
          ...utf8.encode('--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$meta\r\n'),
          ...utf8.encode('--$boundary\r\nContent-Type: $mime\r\n\r\n'),
          ...bytes,
          ...utf8.encode('\r\n--$boundary--'),
        ];
        final res = await _dio.post<Map<String, dynamic>>('$_upload/files',
            queryParameters: {'uploadType': 'multipart', 'fields': 'id'},
            data: Stream.fromIterable([body]),
            options: o.copyWith(headers: {...?o.headers, 'Content-Type': 'multipart/related; boundary=$boundary', 'Content-Length': body.length}));
        return res.data!['id'] as String;
      });

  /// A song file (any size): Drive's resumable upload, sent in one go.
  /// [onProgress] gets (sent, total); [cancel] stops it part way.
  @override
  Future<String> uploadFile(String name, File file,
          {String mime = 'application/octet-stream', void Function(int, int)? onProgress, CancelToken? cancel}) =>
      _authed((o) async {
        final length = await file.length();
        final start = await _dio.post<void>('$_upload/files',
            queryParameters: {'uploadType': 'resumable', 'fields': 'id'},
            data: jsonEncode({'name': name, 'parents': ['appDataFolder']}),
            cancelToken: cancel,
            options: o.copyWith(headers: {
              ...?o.headers,
              'Content-Type': 'application/json; charset=UTF-8',
              'X-Upload-Content-Type': mime,
              'X-Upload-Content-Length': length,
            }));
        final location = start.headers.value('location')!;
        final res = await _dio.put<Map<String, dynamic>>(location,
            data: file.openRead(),
            cancelToken: cancel,
            onSendProgress: onProgress,
            options: o.copyWith(headers: {...?o.headers, 'Content-Type': mime, 'Content-Length': length}));
        return res.data!['id'] as String;
      });

  /// The visible folder [name] at the top of My Drive (made if missing).
  Future<String> folder(String name) => _authed((o) async {
        final res = await _dio.get<Map<String, dynamic>>('$_api/files',
            queryParameters: {
              'q': "name = '${name.replaceAll("'", "\\'")}' and mimeType = 'application/vnd.google-apps.folder' and trashed = false",
              'fields': 'files(id)',
              'spaces': 'drive',
            },
            options: o);
        final found = (res.data!['files'] as List).cast<Map>();
        if (found.isNotEmpty) return found.first['id'] as String;
        final made = await _dio.post<Map<String, dynamic>>('$_api/files',
            queryParameters: {'fields': 'id'},
            data: jsonEncode({'name': name, 'mimeType': 'application/vnd.google-apps.folder'}),
            options: o.copyWith(headers: {...?o.headers, 'Content-Type': 'application/json; charset=UTF-8'}));
        return made.data!['id'] as String;
      });

  /// A song into folder [parent] (雲端音樂庫); returns its file id.
  Future<String> uploadToFolder(String parent, String name, File file,
          {String mime = 'application/octet-stream', void Function(int, int)? onProgress, CancelToken? cancel}) =>
      _authed((o) async {
        final length = await file.length();
        final start = await _dio.post<void>('$_upload/files',
            queryParameters: {'uploadType': 'resumable', 'fields': 'id'},
            data: jsonEncode({'name': name, 'parents': [parent]}),
            cancelToken: cancel,
            options: o.copyWith(headers: {
              ...?o.headers,
              'Content-Type': 'application/json; charset=UTF-8',
              'X-Upload-Content-Type': mime,
              'X-Upload-Content-Length': length,
            }));
        final res = await _dio.put<Map<String, dynamic>>(start.headers.value('location')!,
            data: file.openRead(),
            cancelToken: cancel,
            onSendProgress: onProgress,
            options: o.copyWith(headers: {...?o.headers, 'Content-Type': mime, 'Content-Length': length}));
        return res.data!['id'] as String;
      });

  /// Saves file [id] to [path] (songs: not held in memory).
  @override
  Future<void> downloadTo(String id, String path, {void Function(int, int)? onProgress, CancelToken? cancel}) => _authed((o) async {
        await _dio.download('$_api/files/$id', path,
            queryParameters: {'alt': 'media'}, options: o, cancelToken: cancel, onReceiveProgress: onProgress);
      });

  @override
  Future<void> delete(String id) => _authed((o) => _dio.delete('$_api/files/$id', options: o));

  /// The signed-in account's address, for the settings page.
  Future<String?> email() => _authed((o) async {
        final res = await _dio.get<Map<String, dynamic>>('$_api/about', queryParameters: {'fields': 'user(emailAddress)'}, options: o);
        return (res.data?['user'] as Map?)?['emailAddress'] as String?;
      });
}

/// Not signed in to Google (or the sign-in expired).
class SignedOut implements Exception {
  const SignedOut();
}
