import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // Windows keeps the data in %APPDATA%\<CompanyName>\<ProductName>: 1.15.0
  // renamed the company and opened an empty library.
  test('the Windows data folder stays com.ouo\\OuOPlayer', () {
    final rc = File('windows/runner/Runner.rc').readAsStringSync();
    expect(RegExp(r'VALUE "CompanyName", "([^"]*)"').firstMatch(rc)![1], 'com.ouo');
    expect(RegExp(r'VALUE "ProductName", "([^"]*)"').firstMatch(rc)![1], 'OuOPlayer');
    // path_provider reads them only from the English (US) block: 1.15.0 and
    // the first 1.15.1 had them under Traditional Chinese, and lost the folder.
    final blocks = RegExp(r'BLOCK "([0-9a-fA-F]{8})"').allMatches(rc).map((m) => m[1]!.toLowerCase()).toList();
    expect(blocks, hasLength(1));
    expect(['040904e4', '040904b0'], contains(blocks.single));
    // The uninstaller removes the same folder when asked to.
    expect(File('windows/installer/OuOPlayer.iss').readAsStringSync(), contains(r'{userappdata}\com.ouo\OuOPlayer'));
  });
}
