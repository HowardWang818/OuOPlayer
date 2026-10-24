import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/services/car_browser.dart';

import 'v0120_test.dart' as v0120;

void main() {
  test('the car asking before the library is ready still gets the folders', () async {
    final car = CarLibrary();
    // Android Auto starts the app and asks right away.
    final early = car.children(CarBrowser.root);
    final reloads = <Map<String, dynamic>>[];
    car.subscribe(CarBrowser.root).listen(reloads.add);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // Then the library is ready.
    car.browser = CarBrowser(await v0120.openDb());
    expect((await early).map((m) => m.title), ['音樂庫', '專輯', '演出者', 'Podcast']);
    await Future<void>.delayed(Duration.zero);
    expect(reloads, hasLength(1));
    car.changed();
    await Future<void>.delayed(Duration.zero);
    expect(reloads, hasLength(2));
  });

  test('gives up after the wait limit instead of hanging the car', () async {
    final car = CarLibrary(waitLimit: const Duration(milliseconds: 50));
    expect(await car.children(CarBrowser.root), isEmpty);
  });

  test('local covers go through ArtProvider; online ones stay as they are', () {
    expect(CarBrowser.artUri('/data/user/0/com.ouo.ouoplayer/files/art/ab.jpg').toString(),
        'content://com.ouo.ouoplayer.art/f/${Uri.encodeComponent('/data/user/0/com.ouo.ouoplayer/files/art/ab.jpg')}');
    expect(CarBrowser.artUri('https://img/600.jpg').toString(), 'https://img/600.jpg');
    expect(CarBrowser.artUri(null), isNull);
    expect(CarBrowser.rootExtras[CarBrowser.browsableHint], CarBrowser.styleGrid);
  });
}
