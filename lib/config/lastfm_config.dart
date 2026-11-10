/// Last.fm's API account for OuOPlayer, passed in at build time
/// (release.ps1 reads D:\dev\ouoplayer-keys\lastfm.json). Without it the
/// Last.fm choice in 播放紀錄與統計 is hidden; ListenBrainz needs nothing.
const lastFmKey = String.fromEnvironment('OUO_LASTFM_KEY');
const lastFmSecret = String.fromEnvironment('OUO_LASTFM_SECRET');

bool get lastFmAvailable => lastFmKey.isNotEmpty && lastFmSecret.isNotEmpty;
