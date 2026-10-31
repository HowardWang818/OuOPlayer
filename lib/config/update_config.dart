/// Where in-app updates come from: a Cloudflare Worker (cloud/update-worker)
/// in front of a private R2 bucket. The subdomain must never change — apps
/// already installed would no longer find updates.
const updateServer = 'https://cdn.strawberry-cake67.workers.dev';

/// Windows copies that weren't installed (the zip) can't update themselves:
/// new versions are taken from here.
const releasesPage = 'https://github.com/HowardWang818/OuOPlayer/releases';

/// The Worker answers only requests carrying this header.
const updateHeaders = {'x-ouo-app': 'ouoplayer'};
