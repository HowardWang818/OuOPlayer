import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/ui/pages/collection_page.dart';

void main() {
  test('the top bar takes over as the header fades out', () {
    expect(headerCollapsed(0), isFalse);
    expect(headerCollapsed(200), isFalse);
    expect(headerCollapsed(216), isTrue);
    // All the way up.
    expect(headerCollapsed(244), isTrue);
  });
}
