import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/google_config.dart';
import '../../data/db/database.dart';

/// Access to the user's Google Drive app folder. Phone: Google Play
/// services' account picker (google_sign_in). Windows: the browser, with the
/// answer coming back to a one-off local address (OAuth for desktop apps);
/// its refresh token is kept in the library's settings.
abstract class GoogleAuth {
  factory GoogleAuth(AppDatabase db) => Platform.isAndroid ? _AndroidAuth(db) : _DesktopAuth(db);

  /// An access token; [interactive] may show the account picker / browser.
  /// Null when signed out (or the user cancelled).
  Future<String?> token({bool interactive = false});

  /// Also lets the app keep its own visible files (雲端音樂庫); asks the user.
  Future<bool> addFileScope();

  /// The token was refused (expired / revoked): the next [token] gets a new one.
  Future<void> invalidate(String token);

  Future<void> signOut();
}

/// drive.appdata, plus drive.file once 雲端音樂庫 was turned on.
Future<List<String>> _scopes(AppDatabase db) async =>
    (await db.allSettings())['gdrive_file_scope'] == 'true' ? const [driveAppDataScope, driveFileScope] : const [driveAppDataScope];

class _AndroidAuth implements GoogleAuth {
  _AndroidAuth(this._db);
  final AppDatabase _db;
  static Future<void>? _init;

  Future<void> _ready() => _init ??= GoogleSignIn.instance.initialize();

  @override
  Future<String?> token({bool interactive = false}) async {
    await _ready();
    final client = GoogleSignIn.instance.authorizationClient;
    if (!interactive && (await _db.allSettings())['sync_signed_in'] != 'true') return null;
    final scopes = await _scopes(_db);
    final silent = await client.authorizationForScopes(scopes);
    if (silent != null) return silent.accessToken;
    if (!interactive) return null;
    final granted = await client.authorizeScopes(scopes);
    await _db.setSetting('sync_signed_in', 'true');
    return granted.accessToken;
  }

  @override
  Future<bool> addFileScope() async {
    await _ready();
    await GoogleSignIn.instance.authorizationClient.authorizeScopes(const [driveAppDataScope, driveFileScope]);
    await _db.setSetting('gdrive_file_scope', 'true');
    return true;
  }

  @override
  Future<void> invalidate(String token) async {
    await _ready();
    await GoogleSignIn.instance.authorizationClient.clearAuthorizationToken(accessToken: token);
  }

  @override
  Future<void> signOut() async {
    await _db.setSetting('sync_signed_in', 'false');
    try {
      await _ready();
      await GoogleSignIn.instance.disconnect();
    } catch (_) {}
  }
}

class _DesktopAuth implements GoogleAuth {
  _DesktopAuth(this._db);
  final AppDatabase _db;
  final _dio = Dio();
  String? _access;
  DateTime? _expires;

  static const _tokenUrl = 'https://oauth2.googleapis.com/token';

  @override
  Future<String?> token({bool interactive = false}) async {
    if (_access != null && _expires != null && DateTime.now().isBefore(_expires!)) return _access;
    final refresh = (await _db.allSettings())['gdrive_refresh'];
    if (refresh != null && refresh.isNotEmpty) {
      try {
        final res = await _dio.post<Map<String, dynamic>>(_tokenUrl,
            data: {
              'client_id': googleDesktopClientId,
              'client_secret': googleDesktopClientSecret,
              'refresh_token': refresh,
              'grant_type': 'refresh_token',
            },
            options: Options(contentType: Headers.formUrlEncodedContentType));
        return _keep(res.data!);
      } on DioException catch (e) {
        // Revoked or expired (e.g. 7 days in Google's testing mode): sign in again.
        if (e.response?.statusCode == 400 || e.response?.statusCode == 401) {
          await _db.setSetting('gdrive_refresh', '');
        } else {
          rethrow;
        }
      }
    }
    if (!interactive) return null;
    return _browserSignIn();
  }

  String? _keep(Map<String, dynamic> j) {
    _access = j['access_token'] as String?;
    _expires = DateTime.now().add(Duration(seconds: ((j['expires_in'] as num?) ?? 3600).toInt() - 120));
    return _access;
  }

  /// The browser asks; Google sends the answer to 127.0.0.1 (PKCE).
  Future<String?> _browserSignIn() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = 'http://127.0.0.1:${server.port}';
    final random = Random.secure();
    final verifier = base64UrlEncode(List.generate(48, (_) => random.nextInt(256))).replaceAll('=', '');
    final challenge = base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
    final state = base64UrlEncode(List.generate(16, (_) => random.nextInt(256))).replaceAll('=', '');
    final url = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': googleDesktopClientId,
      'redirect_uri': redirect,
      'response_type': 'code',
      'scope': (await _scopes(_db)).join(' '),
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'access_type': 'offline',
      'prompt': 'consent',
      'state': state,
    });
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
      final request = await server.first.timeout(const Duration(minutes: 5));
      final q = request.uri.queryParameters;
      final ok = q['state'] == state && q['code'] != null;
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write('<!doctype html><meta charset="utf-8"><body style="font-family:sans-serif;text-align:center;padding:48px">'
            '<h2>${ok ? '已登入，可以回到 OuOPlayer 了' : '登入沒有完成'}</h2></body>');
      await request.response.close();
      if (!ok) return null;
      final res = await _dio.post<Map<String, dynamic>>(_tokenUrl,
          data: {
            'client_id': googleDesktopClientId,
            'client_secret': googleDesktopClientSecret,
            'code': q['code'],
            'code_verifier': verifier,
            'grant_type': 'authorization_code',
            'redirect_uri': redirect,
          },
          options: Options(contentType: Headers.formUrlEncodedContentType));
      final refresh = res.data!['refresh_token'] as String?;
      if (refresh != null) await _db.setSetting('gdrive_refresh', refresh);
      return _keep(res.data!);
    } on TimeoutException {
      return null;
    } finally {
      await server.close(force: true);
    }
  }

  @override
  Future<void> invalidate(String token) async {
    _access = null;
    _expires = null;
  }

  @override
  Future<bool> addFileScope() async {
    await _db.setSetting('gdrive_file_scope', 'true');
    _access = null;
    _expires = null;
    // A new browser sign-in with both scopes.
    final t = await _browserSignIn();
    if (t == null) await _db.setSetting('gdrive_file_scope', 'false');
    return t != null;
  }

  @override
  Future<void> signOut() async {
    final refresh = (await _db.allSettings())['gdrive_refresh'];
    _access = null;
    _expires = null;
    await _db.setSetting('gdrive_refresh', '');
    if (refresh != null && refresh.isNotEmpty) {
      try {
        await _dio.post('https://oauth2.googleapis.com/revoke', queryParameters: {'token': refresh});
      } catch (_) {}
    }
  }
}
