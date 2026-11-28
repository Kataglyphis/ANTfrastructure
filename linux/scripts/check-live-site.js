#!/usr/bin/env node
// check-live-site.js <base URL> [route ...] [--files DIR] [--models MANIFEST] [--version V] [--allow-host H] [--isolated] [--scrolls N] [--settle-ms N] [--ready-ms N]: a deployed web app in headless Chrome, its files and models over HTTP and its version.json. See docs/ftp-deploys.md#the-live-site-check
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const https = require('node:https');
const path = require('node:path');
const { findChrome, launch, sleep } = require('./check-docs-sidebars.js');

// A desktop and a phone: the family's apps switch layout between them.
const VIEWPORTS = [[1280, 800], [390, 844]];
const READY = 'flutter-view, flt-glass-pane';
const FILE_JOBS = 8;

function fail(message, code = 2) {
  process.stderr.write(`check-live-site: ${message}\n`);
  process.exit(code);
}

function parseArgs(argv) {
  const opts = { routes: [], files: null, models: null, version: null, allow: [], isolated: false, scrolls: 30, settleMs: 5000, readyMs: 30000 };
  const value = (i, flag) => {
    if (i >= argv.length) fail(`${flag} needs a value`);
    return argv[i];
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--files') opts.files = value(++i, a);
    else if (a === '--models') opts.models = value(++i, a);
    else if (a === '--version') opts.version = value(++i, a);
    else if (a === '--allow-host') opts.allow.push(value(++i, a));
    else if (a === '--isolated') opts.isolated = true;
    else if (a === '--scrolls') opts.scrolls = Number(value(++i, a));
    else if (a === '--settle-ms') opts.settleMs = Number(value(++i, a));
    else if (a === '--ready-ms') opts.readyMs = Number(value(++i, a));
    else if (a.startsWith('--')) fail(`unknown option ${a}`);
    else if (!opts.base) opts.base = a;
    else opts.routes.push(a);
  }
  if (!opts.base || !/^https?:\/\//.test(opts.base)) fail('usage: check-live-site.js <base URL> [route ...] [--files DIR] [--models MANIFEST] [--version V] [--allow-host H] [--isolated] [--scrolls N] [--settle-ms N] [--ready-ms N]');
  if (![opts.scrolls, opts.settleMs, opts.readyMs].every((n) => Number.isInteger(n) && n >= 0)) fail('--scrolls, --settle-ms and --ready-ms take whole numbers');
  if (opts.files && !fs.existsSync(path.join(opts.files, 'index.html'))) fail(`${opts.files} has no index.html`);
  if (opts.models) opts.modelFiles = modelFiles(opts.models);
  opts.base = opts.base.replace(/\/?$/, '/');
  if (!opts.routes.length) opts.routes.push('');
  return opts;
}

// Runs in the page before its scripts: Chrome reports a CSP block to the page, with the full URL.
function cspProbe() {
  window.__liveCheckCsp = [];
  document.addEventListener('securitypolicyviolation', (e) => window.__liveCheckCsp.push(`${e.effectiveDirective} ${e.blockedURI}`));
}

async function checkRoute(browser, events, opts, route, [w, h]) {
  const { send } = browser;
  const url = new URL(route.replace(/^\//, ''), opts.base).href;
  await send('Emulation.setDeviceMetricsOverride', { width: w, height: h, deviceScaleFactor: 1, mobile: w < 600 });
  // A hash route is a same-document navigation: about:blank first, so every route boots the app afresh.
  await send('Page.navigate', { url: 'about:blank' });
  await sleep(200);
  events.reset();
  await send('Page.navigate', { url });
  const look = async (expr) => (await send('Runtime.evaluate', { expression: expr, returnByValue: true })).result.result.value;
  let ready = false;
  for (let i = 0; i * 100 < opts.readyMs && !ready; i++) {
    ready = await look(`!!document.querySelector(${JSON.stringify(READY)})`);
    if (!ready) await sleep(100);
  }
  await sleep(opts.settleMs);
  // Flutter lays out only what is on screen, so a glyph further down is never requested without scrolling.
  for (let i = 0; i < opts.scrolls; i++) {
    await send('Input.dispatchMouseEvent', { type: 'mouseWheel', x: w / 2, y: h / 2, deltaX: 0, deltaY: 600 });
    await sleep(150);
  }
  if (opts.scrolls) await sleep(Math.min(opts.settleMs, 2000));
  const csp = (await look('window.__liveCheckCsp || []')) || [];
  // An isolated app's wasm threads and SharedArrayBuffer need it; a missing COOP or COEP header leaves it false without an error.
  const isolated = !opts.isolated || (await look('self.crossOriginIsolated === true'));
  const base = new URL(opts.base).host;
  const third = [...events.hosts].filter((x) => x !== base && !opts.allow.includes(x));
  const problems = [
    ...(ready ? [] : [`no ${READY} after ${opts.readyMs} ms: the app never started`]),
    ...(isolated ? [] : ['not cross-origin isolated: crossOriginIsolated is false']),
    ...csp.map((c) => `csp-blocked: ${c}`),
    ...third.map((x) => `third-party host: ${x}`),
    ...events.errors,
    ...events.failed,
  ];
  return { label: `${route || '/'} ${w}x${h}`, problems: [...new Set(problems)] };
}

function listFiles(root) {
  const found = [];
  const walk = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      // Dotfiles (.htaccess, .last_build_id) are server config or build bookkeeping, never served.
      if (e.name.startsWith('.')) continue;
      const file = path.join(dir, e.name);
      if (e.isDirectory()) walk(file);
      else found.push(path.relative(root, file).split(path.sep).join('/'));
    }
  };
  walk(root);
  return found.sort();
}

// HTTP/1.1 on purpose: fetch's one HTTP/2 session broke on jonasheinle.de and failed every later request of the sweep.
const AGENTS = { 'http:': new http.Agent({ keepAlive: true, maxSockets: FILE_JOBS }), 'https:': new https.Agent({ keepAlive: true, maxSockets: FILE_JOBS }) };

function request(url, method) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = (u.protocol === 'https:' ? https : http).request(u, { method, agent: AGENTS[u.protocol], headers: { 'Cache-Control': 'no-cache' }, timeout: 30000 }, (res) => {
      const body = [];
      res.on('data', (c) => body.push(c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(body).toString('utf8') }));
    });
    req.on('timeout', () => req.destroy(new Error('timed out after 30 s')));
    req.on('error', reject);
    req.end();
  });
}

// Three attempts, the last one's network error thrown: one dropped connection is no missing file.
async function retried(task) {
  let error;
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      return await task();
    } catch (e) {
      error = e;
      await sleep(1000 * attempt);
    }
  }
  throw error;
}

// The status, or the network error of the last attempt.
async function status(url) {
  try {
    return await retried(async () => {
      const res = await request(url, 'HEAD');
      return res.status === 405 || res.status === 501 ? (await request(url, 'GET')).status : res.status;
    });
  } catch (e) {
    return e.code || e.message;
  }
}

// A route that fails once is retried fresh: a failure that repeats on the retry is the verdict; the first one is only logged.
async function checkRouteTwice(browser, events, opts, route, vp) {
  const firstRun = await checkRoute(browser, events, opts, route, vp);
  if (!firstRun.problems.length) return { label: firstRun.label, problems: [], first: [] };
  const second = await checkRoute(browser, events, opts, route, vp);
  return { label: firstRun.label, problems: second.problems, first: firstRun.problems };
}

async function checkFiles(opts) {
  const files = listFiles(opts.files);
  const bad = [];
  let next = 0;
  const worker = async () => {
    while (next < files.length) {
      const rel = files[next++];
      const url = new URL(rel.split('/').map(encodeURIComponent).join('/'), opts.base).href;
      const got = await status(url);
      if (got !== 200) bad.push(`${got} ${rel}`);
    }
  };
  await Promise.all(Array.from({ length: FILE_JOBS }, worker));
  return { count: files.length, bad: bad.sort() };
}

// models/manifest.json as mirror-app-models.py writes it: every model and license text at models/<its sha256>/.
function modelFiles(file) {
  let manifest = null;
  try {
    manifest = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (e) {
    fail(`${file}: ${e.message}`);
  }
  const files = (manifest?.models || []).flatMap((m) => [m, ...(m?.licenses || [])]);
  const odd = files.find((f) => !/^models\/[0-9a-f]{64}\/[^/]+$/.test(f?.path) || f.path.split('/')[1] !== f.sha256 || !Number.isInteger(f.size));
  if (manifest?.schema_version !== 1 || !files.length || odd) fail(`${file} is no model manifest of schema 1${odd ? `: ${JSON.stringify(odd)}` : ''}`);
  return files;
}

// The whole body hashed: the host can answer a missing model with a page and 200, so only the bytes tell.
function digest(url) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const headers = { 'Cache-Control': 'no-cache', 'Accept-Encoding': 'identity' };
    const req = (u.protocol === 'https:' ? https : http).request(u, { agent: AGENTS[u.protocol], headers, timeout: 30000 }, (res) => {
      const hash = crypto.createHash('sha256');
      let size = 0;
      res.on('data', (c) => { hash.update(c); size += c.length; });
      res.on('end', () => resolve({ status: res.statusCode, type: res.headers['content-type'] || '', size, sha256: hash.digest('hex') }));
    });
    req.on('timeout', () => req.destroy(new Error('timed out after 30 s')));
    req.on('error', reject);
    req.end();
  });
}

async function checkModels(opts) {
  const bad = [];
  for (const f of opts.modelFiles) {
    const url = new URL(f.path.split('/').map(encodeURIComponent).join('/'), opts.base).href;
    try {
      const got = await retried(() => digest(url));
      const page = got.type.startsWith('text/html') ? ', an HTML page in its place' : '';
      if (got.status !== 200) bad.push(`HTTP ${got.status} ${f.path}`);
      else if (got.sha256 !== f.sha256 || got.size !== f.size) bad.push(`${f.path}: ${got.size} bytes, sha256 ${got.sha256}${page}; want ${f.size} bytes, sha256 ${f.sha256}`);
    } catch (e) {
      bad.push(`${e.code || e.message} ${f.path}`);
    }
  }
  return bad;
}

// The isolation headers an isolated app's page must carry, as the hub's flutter-web-isolated.htaccess sets them.
const ISOLATION_HEADERS = { 'cross-origin-opener-policy': 'same-origin', 'cross-origin-embedder-policy': 'require-corp' };

async function checkIsolationHeaders(opts) {
  if (!opts.isolated) return [];
  try {
    const res = await request(opts.base, 'GET');
    return Object.entries(ISOLATION_HEADERS)
      .filter(([name, want]) => res.headers[name] !== want)
      .map(([name, want]) => `${name}: ${res.headers[name] ?? 'missing'}, want ${want}`);
  } catch (e) {
    return [`isolation headers: ${e.code || e.message}`];
  }
}

// version.json as Flutter writes it: the version, and the build number after a +.
const versionOf = (j) => (j.build_number ? `${j.version}+${j.build_number}` : `${j.version}`);

async function checkVersion(opts) {
  let want = opts.version;
  if (!want && opts.files && fs.existsSync(path.join(opts.files, 'version.json'))) want = versionOf(JSON.parse(fs.readFileSync(path.join(opts.files, 'version.json'), 'utf8')));
  if (!want) return null;
  const url = new URL(`version.json?live-check=${Date.now()}`, opts.base).href;
  try {
    const res = await request(url, 'GET');
    if (res.status !== 200) return `version.json: HTTP ${res.status}, want ${want}`;
    const got = versionOf(JSON.parse(res.body));
    return got === want ? null : `version.json: ${got}, want ${want}`;
  } catch (e) {
    return `version.json: ${e.code || e.message}, want ${want}`;
  }
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const chrome = findChrome();
  if (!chrome) fail('no Chrome (CHROME_EXECUTABLE, chrome, chromium): the family image carries Chrome for Testing');
  const requests = new Map();
  const events = {
    hosts: new Set(), errors: [], failed: [],
    reset() { this.hosts.clear(); this.errors = []; this.failed = []; requests.clear(); },
  };
  const onEvent = (m) => {
    const p = m.params || {};
    if (m.method === 'Network.requestWillBeSent') {
      requests.set(p.requestId, p.request.url);
      if (/^https?:/.test(p.request.url)) events.hosts.add(new URL(p.request.url).host);
    } else if (m.method === 'Network.loadingFailed' && !p.canceled) {
      events.failed.push(`request failed (${p.blockedReason || p.errorText}): ${requests.get(p.requestId) || p.requestId}`);
    } else if (m.method === 'Network.responseReceived' && p.response.status >= 400) {
      events.failed.push(`HTTP ${p.response.status}: ${p.response.url}`);
    } else if (m.method === 'Runtime.exceptionThrown') {
      events.errors.push(`exception: ${(p.exceptionDetails.exception?.description || p.exceptionDetails.text).split('\n')[0]}`);
    } else if (m.method === 'Runtime.consoleAPICalled' && p.type === 'error') {
      events.errors.push(`console.error: ${p.args.map((a) => a.value ?? a.description).join(' ')}`);
    } else if (m.method === 'Log.entryAdded' && p.entry.level === 'error') {
      events.errors.push(`console: ${p.entry.text}`);
    }
  };
  const browser = await launch(chrome, ['--disable-gpu'], onEvent);
  const custom = (process.env.CHECK_LIVE_SITE_VIEWPORTS || '').split(/\s+/).filter(Boolean).map((v) => v.split('x').map(Number));
  let failed = 0;
  try {
    await browser.send('Network.enable');
    await browser.send('Log.enable');
    await browser.send('Network.setCacheDisabled', { cacheDisabled: true });
    await browser.send('Page.addScriptToEvaluateOnNewDocument', { source: `(${cspProbe})()` });
    process.stdout.write(`check-live-site: ${opts.base}, ${browser.product} (${chrome})\n`);
    for (const route of opts.routes) {
      for (const vp of custom.length ? custom : VIEWPORTS) {
        const { label, problems, first } = await checkRouteTwice(browser, events, opts, route, vp);
        for (const p of first) process.stdout.write(`flaky: ${label}: ${p}
`);
        if (problems.length) failed++;
        const verdict = problems.length ? 'FAIL' : first.length ? 'ok   (after a retry)' : 'ok  ';
        process.stdout.write(`${verdict} ${label}
${problems.map((p) => `     ${p}
`).join('')}`);
      }
    }
  } finally {
    await browser.close();
  }
  if (opts.files) {
    const { count, bad } = await checkFiles(opts);
    if (bad.length) failed++;
    process.stdout.write(`${bad.length ? 'FAIL' : 'ok  '} ${count} files of ${opts.files}, ${bad.length} not served with 200\n${bad.map((b) => `     ${b}\n`).join('')}`);
  }
  if (opts.models) {
    const wrong = await checkModels(opts);
    if (wrong.length) failed++;
    process.stdout.write(`${wrong.length ? 'FAIL' : 'ok  '} ${opts.modelFiles.length} model files of ${opts.models}, ${wrong.length} not their manifest's bytes\n${wrong.map((b) => `     ${b}\n`).join('')}`);
  }
  const headers = await checkIsolationHeaders(opts);
  if (headers.length) failed++;
  if (opts.isolated) process.stdout.write(`${headers.length ? 'FAIL' : 'ok  '} isolation headers of ${opts.base}\n${headers.map((h) => `     ${h}\n`).join('')}`);
  const version = await checkVersion(opts);
  for (const agent of Object.values(AGENTS)) agent.destroy();
  if (version) failed++;
  process.stdout.write(version ? `FAIL ${version}\n` : (opts.version || opts.files ? 'ok   version.json\n' : ''));
  if (failed) fail(`${failed} check(s) failed; see docs/ftp-deploys.md#the-live-site-check`, 1);
}

main().catch((e) => fail(e.stack || String(e)));
