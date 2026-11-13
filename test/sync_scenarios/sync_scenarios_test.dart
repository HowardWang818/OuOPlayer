// 同步情境 (1.20.3): every sync feature, layer by layer, on simulated devices
// sharing one in-memory Google Drive. After each scenario more syncs must
// change nothing (expectStable): no flip-flopping, no endless re-sending.
//
// 同步
// ├─ 1 剛安裝與重新安裝
// ├─ 2 播放清單（勾選、加歌、移除、排序、改名、刪除、取消同步）
// ├─ 3 已按讚的歌曲
// ├─ 4 歌曲資料（歌名、歌手、專輯、封面、歌詞）
// ├─ 5 收聽紀錄
// ├─ 6 接續播放
// ├─ 7 外觀主題
// ├─ 8 傳歌（雲端中繼站、斷線、暫停）
// ├─ 9 同步紀錄
// └─ 10 三台裝置
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ouoplayer/data/models/track.dart';
import 'package:ouoplayer/services/sync2/now_playing.dart';

import 'harness.dart';

void main() {
  late Cloud cloud;
  late Dev phone, pc;
  setUp(() async {
    cloud = Cloud();
    phone = await Dev.make('手機', cloud, id: 'phone');
    pc = await Dev.make('電腦', cloud, id: 'pc');
  });

  group('1 剛安裝與重新安裝', () {
    test('1.1 雲端是空的：第一次同步不出錯，沒勾選的清單不上傳', () async {
      final a = await phone.song('a');
      await phone.playlist('私人', [a], sync: false);
      final r = await phone.sync();
      expect(r.changed, 0);
      expect(cloud.fingerprint, isNot(contains('私人')));
      expect(cloud.files.values.any((f) => String.fromCharCodes(f.$2).contains('私人')), isFalse);
      await expectStable([phone]);
    });

    test('1.2 另一台剛安裝、什麼都沒有：收到清單，缺的歌傳過去', () async {
      final a = await phone.song('a'), b = await phone.song('b');
      await phone.playlist('通勤', [a, b]);
      await settle([phone, pc]);
      expect(await pc.titles('通勤'), ['a', 'b']);
      expect(await pc.library(), ['a', 'b']);
      expect(cloud.count('v2-song-'), 0);
      await expectStable([phone, pc]);
    });

    test('1.3 另一台剛安裝、有同名清單（沒勾同步）：合併成一份', () async {
      final a = await phone.song('a'), b = await phone.song('b');
      await phone.playlist('通勤', [a, b]);
      await phone.sync();
      final pa = await pc.song('a'), c = await pc.song('c');
      await pc.playlist('通勤', [pa, c], sync: false);
      await settle([phone, pc]);
      expect((await pc.listNames()).where((n) => n == '通勤').length, 1);
      expect((await pc.titles('通勤'))..sort(), ['a', 'b', 'c']);
      expect((await phone.titles('通勤'))..sort(), ['a', 'b', 'c']);
      await expectStable([phone, pc]);
    });

    test('1.4 兩台都剛勾同名清單：合併成一份，共同的歌不重複', () async {
      final a = await phone.song('a'), b = await phone.song('b');
      final pa = await pc.song('a'), c = await pc.song('c');
      await phone.playlist('通勤', [a, b]);
      await pc.playlist('通勤', [pa, c]);
      await settle([phone, pc]);
      for (final d in [phone, pc]) {
        expect((await d.listNames()).where((n) => n == '通勤').length, 1);
        expect((await d.titles('通勤'))..sort(), ['a', 'b', 'c']);
      }
      await expectStable([phone, pc]);
    });

    test('1.5 重新安裝：清單回來、不重複、不重新下載、不會一直以為缺歌', () async {
      final a = await phone.song('a'), b = await phone.song('b');
      await phone.playlist('通勤', [a, b]);
      await settle([phone, pc]);
      // The phone's app is removed and installed again; the PC adds a song meanwhile.
      final again = await phone.reinstall();
      final c = await pc.song('c');
      await pc.db.addToPlaylist(await pc.listId('通勤'), [c]);
      await settle([again, pc]);
      expect(await again.titles('通勤'), ['a', 'b', 'c']);
      expect(await again.library(), ['a', 'b', 'c']);
      expect(cloud.count('v2-song-'), 0, reason: 'nothing left waiting for the old install');
      await expectStable([again, pc]);
    });

    test('1.6 重新安裝：改過的歌名回來', () async {
      final a = await phone.song('Gurenge', artist: 'LiSA');
      await phone.playlist('動畫', [a]);
      await settle([phone, pc]);
      await phone.rename('Gurenge', '紅蓮華');
      await settle([phone, pc]);
      final again = await phone.reinstall();
      expect(await again.library(), ['Gurenge'], reason: 'the file still has the old tags');
      await settle([again, pc]);
      expect(await again.library(), ['紅蓮華']);
      expect(await pc.library(), ['紅蓮華']);
      await expectStable([again, pc]);
    });

    test('1.7 重新安裝：收聽紀錄不會重複計算', () async {
      final a = await phone.song('a');
      await phone.playlist('通勤', [a]);
      await settle([phone, pc]);
      await phone.play('a');
      await pc.play('a');
      await settle([phone, pc]);
      expect(await pc.playsOf('a'), 2);
      final again = await phone.reinstall();
      await settle([again, pc]);
      expect(await pc.playsOf('a'), 2);
      expect(await again.playsOf('a'), 2);
      await expectStable([again, pc]);
    });
  });

  group('2 播放清單', () {
    late int id;
    setUp(() async {
      final a = await phone.song('a'), b = await phone.song('b'), c = await phone.song('c');
      id = await phone.playlist('通勤', [a, b, c]);
      await settle([phone, pc]);
    });

    test('2.1 勾選同步：另一台收到同樣的清單', () async {
      expect(await pc.titles('通勤'), ['a', 'b', 'c']);
      await expectStable([phone, pc]);
    });

    test('2.2 加一首、加多首、同一首加兩次', () async {
      final d = await phone.song('d'), e = await phone.song('e');
      await phone.db.addToPlaylist(id, [d]);
      await phone.db.addToPlaylist(id, [e, await phone.track('a')], allowDuplicates: true);
      await settle([phone, pc]);
      expect(await pc.titles('通勤'), ['a', 'b', 'c', 'd', 'e', 'a']);
      await expectStable([phone, pc]);
    });

    test('2.3 加到指定位置', () async {
      final d = await phone.song('d');
      await phone.db.addToPlaylistAt(id, d, 1);
      await settle([phone, pc]);
      expect(await pc.titles('通勤'), await phone.titles('通勤'));
      await expectStable([phone, pc]);
    });

    test('2.4 移除一首、多選移除、移除重複', () async {
      await phone.db.addToPlaylist(id, [await phone.track('a')], allowDuplicates: true);
      await settle([phone, pc]);
      await phone.db.removePlaylistDuplicates(id);
      await settle([phone, pc]);
      expect(await pc.titles('通勤'), ['a', 'b', 'c']);
      await phone.db.removeFromPlaylist(id, 0);
      await settle([phone, pc]);
      expect(await pc.titles('通勤'), ['b', 'c']);
      final pid = await pc.listId('通勤');
      await pc.db.removeFromPlaylistAt(pid, [0, 1]);
      await settle([phone, pc]);
      expect(await phone.titles('通勤'), isEmpty);
      await expectStable([phone, pc]);
    });

    test('2.5 拖曳排序（兩台輪流）', () async {
      await phone.db.reorderPlaylist(id, 2, 0); // c a b
      await settle([phone, pc]);
      expect(await pc.titles('通勤'), ['c', 'a', 'b']);
      await pc.db.reorderPlaylist(await pc.listId('通勤'), 0, 2); // a b c
      await settle([phone, pc]);
      expect(await phone.titles('通勤'), ['a', 'b', 'c']);
      await expectStable([phone, pc]);
    });

    test('2.6 改名（兩台都改：後改的為準）', () async {
      await phone.db.renamePlaylist(id, '上班');
      await settle([phone, pc]);
      expect(await pc.listNames(), ['上班']);
      await phone.db.renamePlaylist(id, '早上');
      await pc.db.renamePlaylist(await pc.listId('上班'), '晚上');
      await settle([phone, pc]);
      expect(await phone.listNames(), ['晚上']);
      expect(await pc.listNames(), ['晚上']);
      await expectStable([phone, pc]);
    });

    test('2.7 兩台同時改（加、移除、排序）：結果一樣', () async {
      final d = await phone.song('d');
      await phone.db.addToPlaylist(id, [d]);
      final pid = await pc.listId('通勤');
      await pc.db.removeFromPlaylist(pid, 1); // b
      await pc.db.reorderPlaylist(pid, 1, 0); // c a
      await settle([phone, pc]);
      expect(await phone.titles('通勤'), await pc.titles('通勤'));
      expect((await pc.titles('通勤'))..sort(), ['a', 'c', 'd']);
      await expectStable([phone, pc]);
    });

    test('2.8 兩台各自加了同一首：清單裡只出現一次', () async {
      final d = await phone.song('d');
      final pd = await pc.song('d');
      await phone.db.addToPlaylist(id, [d]);
      await pc.db.addToPlaylist(await pc.listId('通勤'), [pd]);
      await settle([phone, pc]);
      expect(await phone.titles('通勤'), ['a', 'b', 'c', 'd']);
      expect(await pc.titles('通勤'), ['a', 'b', 'c', 'd']);
      await expectStable([phone, pc]);
    });

    test('2.9 刪除清單，另一台按「刪除」：只問一次', () async {
      await phone.db.deletePlaylist(id);
      await settle([phone, pc]);
      expect(pc.asked, ['通勤']);
      expect(await pc.listNames(), isEmpty);
      expect(await pc.library(), ['a', 'b', 'c'], reason: 'song files are never deleted');
      await expectStable([phone, pc]);
      expect(pc.asked, ['通勤']);
    });

    test('2.10 刪除清單，另一台按「保留」：留下一般清單、只問一次、不會回到手機', () async {
      pc.deleteOk = false;
      await phone.db.deletePlaylist(id);
      await settle([phone, pc]);
      expect(pc.asked, ['通勤']);
      expect(await pc.titles('通勤'), ['a', 'b', 'c']);
      expect(await pc.engine.isSynced(await pc.listId('通勤')), isFalse);
      expect(await phone.listNames(), isEmpty);
      await expectStable([phone, pc]);
      expect(pc.asked, ['通勤']);
    });

    test('2.11 一台刪除、另一台同時加歌：問要不要刪', () async {
      final d = await pc.song('d');
      await pc.db.addToPlaylist(await pc.listId('通勤'), [d]);
      await phone.db.deletePlaylist(id);
      await phone.sync();
      await settle([pc, phone]);
      expect(pc.asked, ['通勤']);
      expect(await phone.listNames(), isEmpty);
      await expectStable([phone, pc]);
    });

    test('2.12 停止同步：兩台都保留，之後的修改各自獨立', () async {
      await phone.engine.disable(id);
      await phone.db.addToPlaylist(id, [await phone.song('d')]);
      await settle([phone, pc]);
      expect(await phone.titles('通勤'), ['a', 'b', 'c', 'd']);
      expect(await pc.titles('通勤'), ['a', 'b', 'c']);
      await expectStable([phone, pc]);
    });

    test('2.13 停止同步後再勾選：電腦還是只有一份', () async {
      await phone.engine.disable(id);
      await settle([phone, pc]);
      await phone.engine.enable(id);
      await settle([phone, pc]);
      expect((await pc.listNames()).where((n) => n == '通勤').length, 1);
      expect((await phone.listNames()).where((n) => n == '通勤').length, 1);
      expect(await pc.titles('通勤'), ['a', 'b', 'c']);
      await expectStable([phone, pc]);
    });

    test('2.14 刪除檔案：另一台從清單移除，但不刪檔案；這台不再下載回來', () async {
      final a = await phone.track('a');
      await phone.db.takeOutOfLists([a.id]);
      await phone.db.deleteTracks([a.id]);
      await settle([phone, pc]);
      expect(await pc.titles('通勤'), ['b', 'c']);
      expect(await pc.library(), ['a', 'b', 'c']);
      expect(await phone.library(), ['b', 'c']);
      await expectStable([phone, pc]);
    });

    test('2.15 隱藏歌曲或移除資料夾：這台顯示灰色，另一台不受影響，不下載回來', () async {
      final a = await phone.track('a');
      await phone.db.deleteTracks([a.id]);
      await settle([phone, pc]);
      expect(await phone.titles('通勤'), ['~a', 'b', 'c']);
      expect(await pc.titles('通勤'), ['a', 'b', 'c']);
      await expectStable([phone, pc], complete: false);
    });

    test('2.16 兩台都勾選新的同名清單（不是剛安裝）：合併成一份', () async {
      final x = await phone.song('x');
      final px = await pc.song('x');
      await phone.playlist('健身', [x]);
      await pc.playlist('健身', [px]);
      await settle([phone, pc]);
      expect((await phone.listNames()).where((n) => n == '健身').length, 1);
      expect((await pc.listNames()).where((n) => n == '健身').length, 1);
      expect(await pc.titles('健身'), ['x']);
      await expectStable([phone, pc]);
    });

    test('2.17 沒勾選的清單、其他歌曲不上傳', () async {
      final secret = await phone.song('secret');
      await phone.playlist('私人', [secret], sync: false);
      await settle([phone, pc]);
      expect(await pc.listNames(), ['通勤']);
      expect(await pc.library(), ['a', 'b', 'c']);
      expect(cloud.files.values.any((f) => String.fromCharCodes(f.$2).contains('secret')), isFalse);
    });

    test('2.19 兩台同時刪除同一個清單：不用再問', () async {
      await phone.db.deletePlaylist(id);
      await pc.db.deletePlaylist(await pc.listId('通勤'));
      await settle([phone, pc]);
      expect(await phone.listNames(), isEmpty);
      expect(await pc.listNames(), isEmpty);
      expect(phone.asked + pc.asked, isEmpty);
      await expectStable([phone, pc]);
    });

    test('2.18 空的清單也會同步', () async {
      await phone.playlist('空的', []);
      await settle([phone, pc]);
      expect(await pc.titles('空的'), isEmpty);
      expect(await pc.listNames(), contains('空的'));
      await expectStable([phone, pc]);
    });
  });

  group('3 已按讚的歌曲', () {
    setUp(() async {
      await phone.song('a');
      await phone.song('b');
      await pc.song('a');
      await phone.engine.setLikedSynced(true);
      await pc.engine.setLikedSynced(true);
    });

    test('3.1 兩台都開：按讚雙向', () async {
      await phone.like('a');
      await pc.like('a');
      await phone.like('b');
      await settle([phone, pc]);
      expect(await pc.liked(), ['a', 'b']);
      expect(await phone.liked(), ['a', 'b']);
      await expectStable([phone, pc]);
    });

    test('3.2 取消按讚、再按讚', () async {
      await phone.like('a');
      await settle([phone, pc]);
      await pc.like('a', false);
      await settle([phone, pc]);
      expect(await phone.liked(), isEmpty);
      await phone.like('a');
      await settle([phone, pc]);
      expect(await pc.liked(), ['a']);
      await expectStable([phone, pc]);
    });

    test('3.3 一台沒開：不會同步過去', () async {
      await pc.engine.setLikedSynced(false);
      await phone.like('a');
      await settle([phone, pc]);
      expect(await pc.liked(), isEmpty);
      await expectStable([phone, pc]);
    });

    test('3.4 另一台沒有的歌：先灰色，傳過去後補上', () async {
      await phone.like('b');
      await settle([phone, pc]);
      expect(await pc.liked(), ['b']);
      expect((await pc.track('b')).source, isNot(TrackSource.missing));
      await expectStable([phone, pc]);
    });

    test('3.5 刪除檔案：另一台也取消按讚', () async {
      await phone.like('a');
      await settle([phone, pc]);
      final a = await phone.track('a');
      await phone.db.takeOutOfLists([a.id]);
      await phone.db.deleteTracks([a.id]);
      await settle([phone, pc]);
      expect(await pc.liked(), isEmpty);
      await expectStable([phone, pc]);
    });
  });

  group('4 歌曲資料', () {
    setUp(() async {
      final a = await phone.song('Gurenge', artist: 'LiSA');
      final b = await phone.song('b');
      await phone.playlist('動畫', [a, b]);
      await settle([phone, pc]);
    });

    test('4.1 改歌名：另一台跟著改，清單仍是同一首', () async {
      await phone.rename('Gurenge', '紅蓮華');
      await settle([phone, pc]);
      expect(await pc.titles('動畫'), ['紅蓮華', 'b']);
      expect(await pc.library(), ['b', '紅蓮華']);
      await expectStable([phone, pc]);
    });

    test('4.2 連改兩次：另一台是最後的名字', () async {
      await phone.rename('Gurenge', '紅蓮華');
      await settle([phone, pc]);
      await phone.rename('紅蓮華', '紅蓮華 (TV)');
      await settle([phone, pc]);
      expect(await pc.titles('動畫'), ['紅蓮華 (TV)', 'b']);
      await expectStable([phone, pc]);
    });

    test('4.3 兩台都改同一首：後改的為準', () async {
      await phone.rename('Gurenge', '紅蓮華');
      await pc.rename('Gurenge', 'グレンゲ');
      await settle([phone, pc]);
      expect(await phone.library(), await pc.library());
      expect(await pc.library(), ['b', 'グレンゲ']);
      await expectStable([phone, pc]);
    });

    test('4.4 電腦改回去：手機也改回去', () async {
      await phone.rename('Gurenge', '紅蓮華');
      await settle([phone, pc]);
      await pc.rename('紅蓮華', 'Gurenge');
      await settle([phone, pc]);
      expect(await phone.library(), ['Gurenge', 'b']);
      await expectStable([phone, pc]);
    });

    test('4.5 改歌手、專輯', () async {
      await phone.rename('b', 'b', artist: 'B 樂團', album: '第一張');
      await settle([phone, pc]);
      final t = await pc.track('b');
      expect(t.artist, 'B 樂團');
      expect(t.album, '第一張');
      expect(await pc.titles('動畫'), ['Gurenge', 'b']);
      await expectStable([phone, pc]);
    });

    test('4.6 封面：另一台換上，雲端的封面之後刪掉', () async {
      final pic = await phone.setCover('b', 'cat');
      await settle([phone, pc]);
      expect(await pc.cover('b'), pic);
      expect(cloud.count('v2-cover-'), 0);
      await expectStable([phone, pc]);
    });

    test('4.7 多首各自換封面：不會套用到別首', () async {
      await phone.setCover('b', 'cat');
      await phone.setCover('Gurenge', 'dog');
      await settle([phone, pc]);
      expect(await pc.cover('b'), 'picture cat');
      expect(await pc.cover('Gurenge'), 'picture dog');
      await expectStable([phone, pc]);
    });

    test('4.8 歌詞（自己選的優先）', () async {
      final b = await phone.track('b');
      phone.lyrics[b.id] = (lrc: '[00:01]hi', manual: true, at: Clock.tick());
      await phone.set('x', 'y'); // no-op change
      await phone.rename('b', 'b', album: 'new'); // lyrics travel with the synced songs
      await settle([phone, pc]);
      expect(pc.lyrics[(await pc.track('b')).id]?.lrc, '[00:01]hi');
      await expectStable([phone, pc]);
    });

    test('4.9 關閉「歌曲資料」：不送也不收', () async {
      await phone.set('sync_edits', 'false');
      await phone.rename('Gurenge', '紅蓮華');
      await settle([phone, pc]);
      expect(await pc.library(), ['Gurenge', 'b']);
      await expectStable([phone, pc]);
    });

    test('4.10 不在同步清單的歌：改了也不送', () async {
      await phone.song('solo');
      await pc.song('solo');
      await phone.rename('solo', 'ソロ');
      await settle([phone, pc]);
      expect(await pc.library(), contains('solo'));
      await expectStable([phone, pc]);
    });

    test('4.11 雲端有同一首的兩種寫法舊紀錄：不會來回切換', () async {
      await phone.rename('Gurenge', '紅蓮華');
      await settle([phone, pc]);
      await phone.rename('紅蓮華', 'Gurenge');
      await settle([phone, pc]);
      await phone.rename('Gurenge', '紅蓮華');
      await settle([phone, pc]);
      expect(await pc.library(), ['b', '紅蓮華']);
      expect(await phone.library(), ['b', '紅蓮華']);
      await expectStable([phone, pc]);
    });

    test('4.12 另一台有兩份同一首：清單裡那份也改名', () async {
      // The PC got a second copy of the song (another download).
      await pc.song('Gurenge', artist: 'LiSA', file: 'Gurenge (2)');
      await phone.rename('Gurenge', '紅蓮華');
      await settle([phone, pc]);
      expect(await pc.titles('動畫'), ['紅蓮華', 'b']);
      expect(await pc.library(), ['b', '紅蓮華', '紅蓮華']);
      await expectStable([phone, pc]);
    });

    test('4.13 新裝置的檔案已經是新名字：不再下載第二份', () async {
      await phone.rename('Gurenge', '紅蓮華');
      await settle([phone, pc]);
      // A third device whose copy already carries the new name in its tags.
      final laptop = await Dev.make('筆電', cloud, id: 'laptop');
      await laptop.song('紅蓮華', artist: 'LiSA');
      await laptop.song('b');
      await laptop.playlist('動畫', [], sync: false);
      await settle([phone, pc, laptop]);
      expect(await laptop.library(), ['b', '紅蓮華']);
      expect(await laptop.titles('動畫'), ['紅蓮華', 'b']);
      await expectStable([phone, pc, laptop]);
    });
  });

  group('5 收聽紀錄', () {
    setUp(() async {
      final a = await phone.song('a');
      await phone.song('only-phone');
      await phone.playlist('通勤', [a]);
      await settle([phone, pc]);
    });

    test('5.1 兩台的播放都算進去，各一次', () async {
      await phone.play('a');
      await pc.play('a');
      await pc.play('a');
      await settle([phone, pc]);
      expect(await phone.playsOf('a'), 3);
      expect(await pc.playsOf('a'), 3);
      await expectStable([phone, pc]);
    });

    test('5.2 只有一台有的歌也算進統計', () async {
      await phone.play('only-phone');
      await settle([phone, pc]);
      expect(await pc.plays(), 1);
      await expectStable([phone, pc]);
    });

    test('5.3 改過名的歌：播放仍算同一首', () async {
      await phone.rename('a', 'A!');
      await settle([phone, pc]);
      await phone.play('A!');
      await settle([phone, pc]);
      expect(await pc.playsOf('A!'), 1);
      await expectStable([phone, pc]);
    });

    test('5.4 關閉「收聽紀錄」：不送', () async {
      await phone.set('sync_plays', 'false');
      await phone.play('a');
      await settle([phone, pc]);
      expect(await pc.plays(), 0);
      await expectStable([phone, pc]);
    });
  });

  group('6 接續播放', () {
    setUp(() async {
      final a = await phone.song('a'), b = await phone.song('b');
      await phone.playlist('通勤', [a, b]);
      await settle([phone, pc]);
    });

    Future<({ResumeStep step, String why})> check({ResumeMode mode = ResumeMode.ask, DateTime? lastHere, bool playing = false, String? asked}) async {
      final latest = (await pc.engine.nowPlaying.others(pc.id)).firstOrNull;
      return resumeStep(
          mode: mode, latest: latest, now: DateTime.fromMillisecondsSinceEpoch(Clock.now), lastPlayedHere: lastHere, playingHere: playing, asked: asked);
    }

    test('6.1 手機在播：電腦看得到，問要不要接著播', () async {
      await phone.nowPlaying(['a', 'b'], index: 1, positionMs: 42000);
      final latest = (await pc.engine.nowPlaying.others(pc.id)).first;
      expect(latest.current['t'], 'b');
      expect(latest.positionMs, 42000);
      expect((await check()).step, ResumeStep.ask);
    });

    test('6.2 電腦之後播過：不問', () async {
      await phone.nowPlaying(['a']);
      Clock.tick();
      expect((await check(lastHere: DateTime.fromMillisecondsSinceEpoch(Clock.now))).step, ResumeStep.none);
    });

    test('6.3 超過 12 小時：不問', () async {
      await phone.nowPlaying(['a']);
      Clock.pass(const Duration(hours: 13));
      expect((await check()).why, startsWith('older than 12 h'));
    });

    test('6.4 同一筆只問一次；手機再播就再問', () async {
      await phone.nowPlaying(['a']);
      final latest = (await pc.engine.nowPlaying.others(pc.id)).first;
      expect((await check(asked: '${latest.device}:${latest.at}')).step, ResumeStep.none);
      await phone.nowPlaying(['b']);
      expect((await check(asked: '${latest.device}:${latest.at}')).step, ResumeStep.ask);
    });

    test('6.5 自動接續 / 不接續 / 這台正在播', () async {
      await phone.nowPlaying(['a']);
      expect((await check(mode: ResumeMode.auto)).step, ResumeStep.load);
      expect((await check(mode: ResumeMode.never)).step, ResumeStep.none);
      expect((await check(playing: true)).step, ResumeStep.none);
    });

    test('6.6 重新安裝後：舊安裝留下的舊紀錄不會蓋過新的', () async {
      await phone.nowPlaying(['a'], at: Clock.now - 3600000);
      final again = await phone.reinstall();
      await again.nowPlaying(['b']);
      final latest = (await pc.engine.nowPlaying.others(pc.id)).first;
      expect(latest.current['t'], 'b');
    });

    test('6.7 佇列裡的歌：改過名的、這台沒有的都對得上', () async {
      await phone.rename('a', 'A!');
      await settle([phone, pc]);
      final extra = await phone.song('only-phone');
      expect(extra.title, 'only-phone');
      await phone.nowPlaying(['A!', 'only-phone', 'b']);
      final latest = (await pc.engine.nowPlaying.others(pc.id)).first;
      final queue = queueHere(latest, await pc.db.tracks(), await pc.db.db.query('track_edits'));
      expect([for (final t in queue) t?.title], ['A!', null, 'b']);
    });

    test('6.8 自己的紀錄不算另一台的', () async {
      await pc.nowPlaying(['a']);
      expect(await pc.engine.nowPlaying.others(pc.id), isEmpty);
    });
  });

  group('7 外觀主題', () {
    Future<void> pick(Dev d, String theme) async {
      await d.set('color_theme', theme);
      await d.set('color_theme_at', '${Clock.tick()}');
    }

    test('7.1 一台換了，另一台跟著換', () async {
      await pick(phone, 'sakura');
      await settle([phone, pc]);
      expect(await pc.setting('color_theme'), 'sakura');
      await expectStable([phone, pc]);
    });

    test('7.2 兩台都換：後換的為準', () async {
      await pick(phone, 'sakura');
      await pick(pc, 'ocean');
      await settle([phone, pc]);
      expect(await phone.setting('color_theme'), 'ocean');
      expect(await pc.setting('color_theme'), 'ocean');
      await expectStable([phone, pc]);
    });

    test('7.3 關閉「外觀主題」：不跟著換', () async {
      await pc.set('sync_theme', 'false');
      await pick(phone, 'sakura');
      await settle([phone, pc]);
      expect(await pc.setting('color_theme'), isNull);
      await expectStable([phone, pc]);
    });
  });

  group('8 傳歌', () {
    test('8.1 缺的歌經雲端傳過去，傳完雲端清空', () async {
      final a = await phone.song('a'), b = await phone.song('b');
      await pc.song('a');
      await phone.playlist('通勤', [a, b]);
      await settle([phone, pc]);
      expect(await pc.library(), ['a', 'b']);
      expect(cloud.count('v2-song-'), 0);
      expect(cloud.count('v2-art-'), 0);
      await expectStable([phone, pc]);
    });

    test('8.2 中繼站滿了：等另一台下載後繼續', () async {
      final songs = [for (final n in ['a', 'b', 'c']) await phone.song(n)];
      await phone.playlist('通勤', songs);
      await phone.sync();
      await pc.sync();
      await phone.sync();
      await phone.transfer(cap: File(songs.first.uri).lengthSync() + 10); // room for one song file
      expect(cloud.count('v2-song-'), 1);
      await settle([phone, pc]);
      expect(await pc.library(), ['a', 'b', 'c']);
      await expectStable([phone, pc]);
    });

    test('8.3 斷線時同步失敗，連上後接著完成', () async {
      final a = await phone.song('a');
      await phone.playlist('通勤', [a]);
      cloud.offline = true;
      await expectLater(phone.sync(), throwsA(anything));
      cloud.offline = false;
      await settle([phone, pc]);
      expect(await pc.titles('通勤'), ['a']);
      await expectStable([phone, pc]);
    });

    test('8.4 暫停：這一輪停下，繼續後傳完', () async {
      final songs = [for (final n in ['a', 'b']) await phone.song(n)];
      await phone.playlist('通勤', songs);
      await pc.sync();
      await phone.sync();
      phone.engine.pause();
      expect(await phone.transfer(), 0);
      phone.engine.resume();
      await settle([phone, pc]);
      expect(await pc.library(), ['a', 'b']);
      await expectStable([phone, pc]);
    });

    test('8.5 重新安裝的那台：歌還在就不再傳，雲端不會一直留著歌', () async {
      final a = await phone.song('a');
      await phone.playlist('通勤', [a]);
      await settle([phone, pc]);
      final again = await phone.reinstall();
      await settle([again, pc]);
      final b = await pc.song('b');
      await pc.db.addToPlaylist(await pc.listId('通勤'), [b]);
      await settle([again, pc]);
      expect(await again.library(), ['a', 'b']);
      expect(cloud.count('v2-song-'), 0);
      await expectStable([again, pc]);
    });
  });

  group('8b 沒有任何一台有的歌', () {
    test('8.6 兩台都沒有檔案的歌：顯示灰色，不會一直重新同步', () async {
      final a = await phone.song('a'), b = await phone.song('b');
      await phone.playlist('通勤', [a, b]);
      await settle([phone, pc]);
      // Both lose the file of 'a' (folder removed on both).
      await phone.db.deleteTracks([(await phone.track('a')).id]);
      await pc.db.deleteTracks([(await pc.track('a')).id]);
      await settle([phone, pc]);
      expect(await phone.titles('通勤'), ['~a', 'b']);
      await expectStable([phone, pc]);
    });
  });

  group('9 同步紀錄', () {
    test('9.1 收到的變更都寫進紀錄，而且寫出來自哪一台', () async {
      final a = await phone.song('a'), b = await phone.song('b');
      final id = await phone.playlist('通勤', [a]);
      await phone.engine.setLikedSynced(true);
      await pc.engine.setLikedSynced(true);
      await settle([phone, pc]);
      await phone.db.addToPlaylist(id, [b]);
      await phone.db.removeFromPlaylist(id, 0);
      await phone.like('b');
      await settle([phone, pc]);
      await phone.rename('b', 'B!');
      await settle([phone, pc]);
      final entries = await pc.log();
      expect(entries, containsAll(['「通勤」加入「b」', '「通勤」移除「a」', '按讚「b」', '歌名「b」改為「B!」']));
      final raw = await phoneLogDevices(pc);
      expect(raw.where((d) => d != '手機'), isEmpty, reason: 'every line names the phone: $raw');
      await phone.like('B!', false);
      await settle([phone, pc]);
      expect(await pc.log(), contains('取消按讚「B!」'));
      expect((await phoneLogDevices(pc)).where((d) => d != '手機'), isEmpty);
    });

    test('9.2 這台自己的動作不寫進這台的紀錄', () async {
      final a = await phone.song('a');
      final id = await phone.playlist('通勤', [a]);
      await settle([phone, pc]);
      await phone.db.renamePlaylist(id, '上班');
      await phone.rename('a', 'A!');
      await settle([phone, pc]);
      expect(await phone.log(), isEmpty);
    });
  });

  group('10 三台裝置', () {
    test('10.1 三台各自改：最後三台都一樣', () async {
      final laptop = await Dev.make('筆電', cloud, id: 'laptop');
      final a = await phone.song('a'), b = await phone.song('b');
      await phone.playlist('通勤', [a, b]);
      await settle([phone, pc, laptop]);
      await pc.db.addToPlaylist(await pc.listId('通勤'), [await pc.song('c')]);
      await laptop.db.removeFromPlaylist(await laptop.listId('通勤'), 0);
      await phone.rename('b', 'B!');
      await settle([phone, pc, laptop]);
      for (final d in [phone, pc, laptop]) {
        expect(await d.titles('通勤'), ['B!', 'c'], reason: d.name);
      }
      await expectStable([phone, pc, laptop]);
    });
  });
}

/// The device names on the lines of a device's 同步紀錄.
Future<List<String?>> phoneLogDevices(Dev d) async {
  final raw = await d.setting('sync_log');
  if (raw == null) return const [];
  return [for (final m in jsonDecode(raw) as List) (m as Map)['d'] as String?];
}
