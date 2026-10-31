// OuOPlayer update server (Cloudflare Worker in front of a private R2 bucket).
//
// Only these requests are answered, and only from the app:
//   GET /latest.json                                  newest version info
//   GET /v0.18.0/OuOPlayer-0.18.0-arm64-v8a.apk       one APK
//   GET /latest-windows.json                          the same for Windows
//   GET /windows/v0.23.0/OuOPlayer-0.23.0-windows-setup.exe
// Everything else gets a plain 404, so scanners learn nothing.

const APP_HEADER = 'x-ouo-app';
const APP_ID = 'ouoplayer';
const APK = /^\/v\d+\.\d+\.\d+\/OuOPlayer-\d+\.\d+\.\d+-(arm64-v8a|armeabi-v7a|x86_64)\.apk$/;
const SETUP = /^\/windows\/v\d+\.\d+\.\d+\/OuOPlayer-\d+\.\d+\.\d+-windows-setup\.exe$/;

const notFound = () => new Response('Not found', { status: 404 });

export default {
  async fetch(request, env) {
    if (request.method !== 'GET' && request.method !== 'HEAD') return notFound();
    if (request.headers.get(APP_HEADER) !== APP_ID) return notFound();

    const path = new URL(request.url).pathname;
    const latest = path === '/latest.json' || path === '/latest-windows.json';
    const setup = SETUP.test(path);
    if (!latest && !setup && !APK.test(path)) return notFound();

    // A few checks / downloads a minute per address is plenty for real phones.
    const ip = request.headers.get('cf-connecting-ip') ?? 'unknown';
    const { success } = await (latest ? env.CHECK_LIMIT : env.APK_LIMIT).limit({ key: ip });
    if (!success) return new Response('Too many requests', { status: 429, headers: { 'retry-after': '60' } });

    const object = request.method === 'HEAD' ? await env.UPDATES.head(path.slice(1)) : await env.UPDATES.get(path.slice(1));
    if (!object) return notFound();

    const headers = new Headers();
    object.writeHttpMetadata(headers);
    headers.set('etag', object.httpEtag);
    headers.set('content-length', String(object.size));
    headers.set('content-type', latest ? 'application/json; charset=utf-8' : setup ? 'application/octet-stream' : 'application/vnd.android.package-archive');
    headers.set('cache-control', latest ? 'no-cache' : 'private, max-age=86400');
    return new Response(request.method === 'HEAD' ? null : object.body, { headers });
  },
};
