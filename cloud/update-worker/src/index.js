// OuOPlayer update server (Cloudflare Worker in front of a private R2 bucket).
//
// Only these requests are answered, and only from the app:
//   GET /latest.json                                  newest version info
//   GET /v0.18.0/OuOPlayer-0.18.0-arm64-v8a.apk       one APK
//   GET /latest-windows.json                          the same for Windows
//   GET /windows/v0.23.0/OuOPlayer-0.23.0-windows-setup.exe
//   GET /components/ytdlp-0.18.1/arm64-v8a/python.zip  download parts (v1.15.0)
//   GET /hello                                        anonymous daily count (v1.18.0)
//   GET /stats?key=…                                  the counts, for the developer
// Everything else gets a plain 404, so scanners learn nothing.
//
// /hello: once a day the app sends a random id (made on the device, tied to
// nothing), its version and platform, unless 匿名使用人數統計 is off. Stored
// in D1 (binding STATS, schema.sql) one row per id per day, kept 90 days;
// no address or anything else is stored. Without the binding it just answers.

const APP_HEADER = 'x-ouo-app';
const APP_ID = 'ouoplayer';
const APK = /^\/v\d+\.\d+\.\d+\/OuOPlayer-\d+\.\d+\.\d+-(arm64-v8a|armeabi-v7a|x86_64)\.apk$/;
const SETUP = /^\/windows\/v\d+\.\d+\.\d+\/OuOPlayer-\d+\.\d+\.\d+-windows-setup\.exe$/;
const COMPONENT = /^\/components\/ytdlp-\d+\.\d+\.\d+\/(arm64-v8a|armeabi-v7a|x86_64)\/(python|ffmpeg)\.zip$/;

const notFound = () => new Response('Not found', { status: 404 });
const ID = /^[0-9a-f]{16}$/;
const VERSION = /^\d+\.\d+\.\d+$/;
const PLATFORMS = new Set(['android', 'windows']);

async function hello(request, env) {
  const id = request.headers.get('x-ouo-id') ?? '';
  const ver = request.headers.get('x-ouo-ver') ?? '';
  const platform = request.headers.get('x-ouo-platform') ?? '';
  if (!ID.test(id) || !VERSION.test(ver) || !PLATFORMS.has(platform)) return notFound();
  if (env.STATS) {
    const day = new Date().toISOString().slice(0, 10);
    await env.STATS.prepare('INSERT OR REPLACE INTO seen (day, id, ver, platform) VALUES (?, ?, ?, ?)').bind(day, id, ver, platform).run();
    if (Math.random() < 0.01) await env.STATS.prepare("DELETE FROM seen WHERE day < date('now', '-90 days')").run();
  }
  return new Response(null, { status: 204 });
}

const esc = (v) => String(v).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

async function stats(url, env) {
  if (!env.STATS_KEY || url.searchParams.get('key') !== env.STATS_KEY || !env.STATS) return notFound();
  const q = (sql) => env.STATS.prepare(sql).all().then((r) => r.results);
  const days = await q("SELECT day, platform, COUNT(*) AS n FROM seen WHERE day >= date('now', '-30 days') GROUP BY day, platform ORDER BY day DESC");
  const versions = await q("SELECT platform, ver, COUNT(DISTINCT id) AS n FROM seen WHERE day >= date('now', '-7 days') GROUP BY platform, ver ORDER BY n DESC");
  const month = await q("SELECT platform, COUNT(DISTINCT id) AS n FROM seen WHERE day >= date('now', '-30 days') GROUP BY platform");
  const byDay = {};
  for (const r of days) (byDay[r.day] ??= { android: 0, windows: 0 })[r.platform] = r.n;
  const table = (head, rows) => `<table><tr>${head.map((h) => `<th>${h}</th>`).join('')}</tr>${rows.map((r) => `<tr>${r.map((c) => `<td>${esc(c)}</td>`).join('')}</tr>`).join('')}</table>`;
  const html = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>OuOPlayer 使用人數</title>
<style>body{font:15px system-ui,sans-serif;margin:16px;max-width:640px}table{border-collapse:collapse;margin:8px 0 24px}td,th{border-bottom:1px solid #ccc;padding:4px 12px;text-align:left}</style>
<h1>OuOPlayer 使用人數</h1>
<h2>最近 30 天（不重複）</h2>${table(['平台', '人數'], month.map((r) => [r.platform, r.n]))}
<h2>每天</h2>${table(['日期', 'Android', 'Windows'], Object.entries(byDay).map(([d, v]) => [d, v.android, v.windows]))}
<h2>最近 7 天的版本</h2>${table(['平台', '版本', '人數'], versions.map((r) => [r.platform, r.ver, r.n]))}`;
  return new Response(html, { headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' } });
}

export default {
  async fetch(request, env) {
    if (request.method !== 'GET' && request.method !== 'HEAD') return notFound();
    const url = new URL(request.url);
    if (url.pathname === '/stats') return stats(url, env);
    if (request.headers.get(APP_HEADER) !== APP_ID) return notFound();

    const path = url.pathname;
    if (path === '/hello') {
      const ip = request.headers.get('cf-connecting-ip') ?? 'unknown';
      const { success } = await env.CHECK_LIMIT.limit({ key: ip });
      return success ? hello(request, env) : new Response('Too many requests', { status: 429 });
    }
    const latest = path === '/latest.json' || path === '/latest-windows.json';
    const setup = SETUP.test(path);
    const component = COMPONENT.test(path);
    if (!latest && !setup && !component && !APK.test(path)) return notFound();

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
    headers.set('content-type', latest ? 'application/json; charset=utf-8' : setup ? 'application/octet-stream' : component ? 'application/zip' : 'application/vnd.android.package-archive');
    headers.set('cache-control', latest ? 'no-cache' : 'private, max-age=86400');
    return new Response(request.method === 'HEAD' ? null : object.body, { headers });
  },
};
