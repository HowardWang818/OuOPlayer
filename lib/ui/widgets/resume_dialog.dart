import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/sync2/now_playing.dart';

/// m:ss
String progressTime(int ms) {
  final d = Duration(milliseconds: ms < 0 ? 0 : ms);
  return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}

/// A dialog that closes by itself once playback starts here ([playing]):
/// answering it then would jump songs while listening. Returns
/// [startedPlaying] in that case.
Future<Object?> _show(BuildContext context, Stream<bool>? playing, WidgetBuilder builder) => showDialog<Object>(
      context: context,
      useRootNavigator: true,
      builder: (c) => playing == null ? builder(c) : _ClosesOnPlay(playing: playing, child: builder(c)),
    );

/// What a resume dialog returns when playing closed it.
const startedPlaying = #startedPlaying;

class _ClosesOnPlay extends StatefulWidget {
  const _ClosesOnPlay({required this.playing, required this.child});
  final Stream<bool> playing;
  final Widget child;

  @override
  State<_ClosesOnPlay> createState() => _ClosesOnPlayState();
}

class _ClosesOnPlayState extends State<_ClosesOnPlay> {
  late final StreamSubscription<bool> _sub;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.playing.listen((on) {
      if (on) _close();
    });
  }

  void _close() {
    if (_closed || !mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    _closed = true;
    final nav = Navigator.of(context);
    route.isCurrent ? nav.pop(startedPlaying) : nav.removeRoute(route, startedPlaying);
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 「要接著播嗎？」 (only the other device played since). Null: closed
/// without answering; [startedPlaying]; else the answer and 記住我的選擇.
Future<Object?> showResumeAsk(BuildContext context, NowPlaying offer, {required Stream<bool> playing}) {
  var remember = false;
  return _show(
    context,
    playing,
    (_) => StatefulBuilder(
      builder: (c, setState) => AlertDialog(
        title: const Text('要接著播嗎？'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('在${offer.deviceName}上聽到〈${offer.current['t']}〉${progressTime(offer.positionMs)}，要從這裡接著播嗎？（不會自動開始播放）'),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('記住我的選擇，不再顯示'),
            value: remember,
            onChanged: (v) => setState(() => remember = v == true),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, (yes: false, remember: remember)), child: const Text('不要')),
          FilledButton(autofocus: true, onPressed: () => Navigator.pop(c, (yes: true, remember: remember)), child: const Text('接著播')),
        ],
      ),
    ),
  );
}

/// A row of [showResumeChoice].
class ResumeChoice {
  const ResumeChoice(this.label, this.progress, {this.here = false});
  final String label;
  final NowPlaying progress;

  /// What is in the player now.
  final bool here;
}

/// 「要從哪裡接著播？」 (both played, or from 接續播放狀態). [playing] null: it
/// stays up while playing (opened by hand). Returns the [ResumeChoice] taken,
/// null for 取消, or [startedPlaying].
Future<Object?> showResumeChoice(BuildContext context, List<ResumeChoice> choices, {Stream<bool>? playing}) {
  var picked = choices.indexWhere((c) => c.here);
  if (picked < 0) picked = 0;
  return _show(
    context,
    playing,
    (_) => StatefulBuilder(
      builder: (c, setState) {
        final scheme = Theme.of(c).colorScheme;
        return AlertDialog(
          scrollable: true,
          title: const Text('要從哪裡接著播？'),
          contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
          content: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final (i, choice) in choices.indexed)
                ListTile(
                  selected: i == picked,
                  leading: Icon(i == picked ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                  title: Text(choice.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('〈${choice.progress.current['t']}〉',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.onSurfaceVariant)),
                  trailing: Text(progressTime(choice.progress.positionMs), style: const TextStyle(fontSize: 14)),
                  onTap: () => setState(() => picked = i),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
            FilledButton(autofocus: true, onPressed: () => Navigator.pop(c, choices[picked]), child: const Text('接著播')),
          ],
        );
      },
    ),
  );
}
