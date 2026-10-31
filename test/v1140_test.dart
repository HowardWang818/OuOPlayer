import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/audio_handler.dart';
import 'package:ouoplayer/ui/pages/settings/shortcut_settings.dart';
import 'package:ouoplayer/ui/shell/app_shortcuts.dart';

import 'v0120_test.dart' as v0120;

void main() {
  group('shuffling, songs not heard yet first', () {
    final songs = List.generate(20, (i) => i);
    bool heard(int i) => i.isEven;

    test('the unheard come first, the heard after, each part shuffled', () {
      final q = shuffledQueue(songs, 4, Random(1), heard: heard);
      expect(q.first, 4);
      expect(q.sublist(1, 11).every((i) => !heard(i)), isTrue);
      expect(q.sublist(11).every(heard), isTrue);
      expect(q.toSet(), songs.toSet());
      expect(q.sublist(1, 11), isNot([1, 3, 5, 7, 9, 11, 13, 15, 17, 19]));
    });

    test('off, nothing is sorted out', () {
      final q = shuffledQueue(songs, 0, Random(2));
      expect(q.sublist(1).take(10).every((i) => !heard(i)), isFalse);
      expect(unheardFirst(songs, null), songs);
    });

    test('the first song is an unheard one, while there are any', () {
      for (var seed = 0; seed < 50; seed++) {
        expect(heard(songs[randomStart(songs, Random(seed), heard: heard)]), isFalse);
      }
      expect(randomStart(songs, Random(3), heard: (_) => true), inInclusiveRange(0, 19));
      expect(randomStart(songs, Random(3)), inInclusiveRange(0, 19));
    });
  });

  test('a song counts as heard after 30 seconds, or nearly all of a shorter one', () async {
    final db = await v0120.openDb();
    Future<void> play(String id, int? durationMs, Duration listened) async {
      final t = Track(id: id, uri: '/m/$id.m4a', title: id, durationMs: durationMs);
      await db.addHistory(t);
      await db.updateListening(await db.startListening(t, DateTime(2026)), listened);
    }

    await play('skipped', 200000, const Duration(seconds: 3));
    await play('listened', 200000, const Duration(seconds: 30));
    await play('short', 20000, const Duration(seconds: 18));
    await play('short skipped', 20000, const Duration(seconds: 17));
    await play('no length', null, const Duration(seconds: 29));
    await play('no length listened', null, const Duration(seconds: 31));
    expect(await db.heardTracks(), {'listened', 'short', 'no length listened'});
  });

  group('the key capture dialog', () {
    Future<List<({KeyCombo? combo})?>> open(WidgetTester tester) async {
      final results = <({KeyCombo? combo})?>[];
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => results.add(await showDialog<({KeyCombo? combo})>(
              context: context,
              builder: (_) => const KeyCapture(action: AppAction.mute),
            )),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return results;
    }

    testWidgets('Esc stays in the dialog and saves 未指定', (tester) async {
      final results = await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(KeyCapture), findsOneWidget);
      expect(find.text('未指定'), findsOneWidget);
      await tester.tap(find.text('儲存'));
      await tester.pumpAndSettle();
      expect(find.byType(KeyCapture), findsNothing);
      expect(results.single, isNotNull);
      expect(results.single!.combo, isNull);
    });

    testWidgets('a key is picked and presses nothing else', (tester) async {
      final results = await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(find.byType(KeyCapture), findsOneWidget);
      expect(results, isEmpty);
    });

    testWidgets('取消 leaves the key alone', (tester) async {
      final results = await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(results.single, isNull);
    });
  });
}
