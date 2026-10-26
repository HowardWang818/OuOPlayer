# OuOPlayer fork

Copy of just_audio_media_kit 2.1.0 (public domain, see LICENSE) with one addition:
`JustAudioMediaKit.audioFilter` sets mpv's `af` option on all players, used for volume normalization.

Further patches (v1.0.1 / Windows v0.5.0), all marked `OuOPlayer patch` in `lib/mediakit_player.dart`:
- `load()` stops waiting after 10 s if mpv never reports the file ready.
- `release()` cancels the stream subscriptions before disposing the player.
- mpv's `sub-auto` is off (a same-name `.lrc` isn't a subtitle file).
