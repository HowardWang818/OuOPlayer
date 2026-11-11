import 'dart:io';

import 'package:flutter/services.dart';

import '../config/links.dart';
import '../config/version.dart';

/// 回報問題: a new GitHub issue with the version and device filled in (no
/// personal data: no library, account or file names).
class BugReport {
  static Future<String> deviceLine() async {
    if (Platform.isAndroid) {
      try {
        final m = await const MethodChannel('ouo/device').invokeMapMethod<String, String>('info');
        if (m != null) return '${m['model']}，${m['os']}';
      } catch (_) {}
      return 'Android';
    }
    return 'Windows ${Platform.operatingSystemVersion}';
  }

  /// The address of a new issue with [device] in its body.
  static String url(String device) {
    final body = '''**問題描述**


**重現步驟**


**預期結果**


---
OuOPlayer $appVersion（${Platform.isAndroid ? 'Android' : 'Windows'}）
$device''';
    return Uri.parse('$issuesUrl/new').replace(queryParameters: {'body': body}).toString();
  }

  static Future<String> newIssueUrl() async => url(await deviceLine());
}
