#!/usr/bin/env node
// check-docs-sidebars.js <site dir | https URL>: click every sidebar toggle of a built Sphinx-book or dartdoc site in headless Chrome. See docs/docs-sites.md#the-sidebar-toggle-check
'use strict';

const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const LAYOUTS = {
  // Sphinx-book switches at 1200 (secondary toggle), 992 (primary collapses or opens a dialog) and 768.
  sphinx: {
    marker: '_static/scripts/sphinx-book-theme.js',
    viewports: [[1400, 900], [1100, 900], [850, 900], [400, 800]],
    sidebars: [
      { name: 'primary', sidebar: '#pst-primary-sidebar', dialog: '#pst-primary-sidebar-modal', toggle: '.primary-toggle' },
      { name: 'secondary', sidebar: '#pst-secondary-sidebar', dialog: '#pst-secondary-sidebar-modal', toggle: '.secondary-toggle' },
    ],
  },
  // dartdoc's left sidebar is a drawer at 840 and below, closed by the overlay under it.
  dartdoc: {
    marker: 'static-assets/docs.dart.js',
    viewports: [[1400, 900], [800, 900], [400, 800]],
    sidebars: [{ name: 'left', sidebar: '#dartdoc-sidebar-left', toggle: '#sidenav-left-toggle', close: '#overlay-under-drawer' }],
  },
};

const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css',
  '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.wasm': 'application/wasm',
  '.woff2': 'font/woff2', '.woff': 'font/woff', '.ico': 'image/x-icon' };

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function fail(message, code = 2) {
  process.stderr.write(`check-docs-sidebars: ${message}\n`);
  process.exit(code);
}

function findChrome() {
  // google-chrome before chromium: a runner's chromium can be a snap launcher, which took over 15 s to start.
  const candidates = [process.env.CHROME_EXECUTABLE, 'chrome', 'google-chrome', 'chromium', 'chromium-browser'];
  for (const c of candidates.filter(Boolean)) {
    const found = c.includes('/') ? fs.existsSync(c) : spawnSync('sh', ['-c', `command -v ${c}`]).status === 0;
    if (found) return c;
  }
  return null;
}

function serve(root) {
  const server = http.createServer((req, res) => {
    let rel = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    let file = path.join(root, rel);
    if (!file.startsWith(root)) { res.writeHead(403).end(); return; }
    if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, 'index.html');
    fs.readFile(file, (err, body) => {
      if (err) { res.writeHead(404).end(); return; }
      res.writeHead(200, { 'Content-Type': TYPES[path.extname(file).toLowerCase()] || 'application/octet-stream' }).end(body);
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

async function launch(chrome) {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'docs-sidebars-'));
  const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu', '--no-first-run',
    '--disable-dev-shm-usage', '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'],
  { stdio: 'ignore' });
  const portFile = path.join(profile, 'DevToolsActivePort');
  for (let i = 0; i < 600 && !fs.existsSync(portFile); i++) await sleep(100);
  if (!fs.existsSync(portFile)) { proc.kill('SIGKILL'); fail(`${chrome} started no DevTools endpoint in 60 s`); }
  const port = fs.readFileSync(portFile, 'utf8').split('\n')[0];
  let targets = [];
  for (let i = 0; i < 50 && !targets.some((t) => t.type === 'page'); i++) {
    try { targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json(); } catch { await sleep(100); }
  }
  const page = targets.find((t) => t.type === 'page');
  if (!page) { proc.kill('SIGKILL'); fail(`${chrome} opened no page`); }
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
  let id = 0;
  const pending = new Map();
  const loaded = [];
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } else if (m.method === 'Page.loadEventFired') loaded.push(m);
  };
  const send = (method, params = {}) => new Promise((resolve) => { const i = ++id; pending.set(i, resolve); ws.send(JSON.stringify({ id: i, method, params })); });
  const close = () => { ws.close(); proc.kill('SIGKILL'); fs.rmSync(profile, { recursive: true, force: true }); };
  await send('Page.enable');
  const product = (await send('Browser.getVersion')).result.product;
  return { send, loaded, close, product };
}

// Runs in the page: the sidebar's state and the one toggle a user can see.
function probe(spec) {
  const vw = document.documentElement.clientWidth;
  const onScreen = (e) => {
    const cs = getComputedStyle(e);
    const r = e.getBoundingClientRect();
    return cs.display !== 'none' && cs.visibility !== 'hidden' && Number(cs.opacity) > 0 && r.width > 0 && r.right > 0 && r.left < vw;
  };
  const dialog = spec.dialog && document.querySelector(spec.dialog);
  const sidebar = document.querySelector(spec.sidebar);
  const state = !sidebar && !dialog ? 'absent' : (dialog && dialog.open) || (sidebar && onScreen(sidebar)) ? 'open' : 'closed';
  const shown = [...document.querySelectorAll(spec.toggle)].find((e) => e.getBoundingClientRect().width > 0);
  let toggle = null;
  if (shown) {
    const r = shown.getBoundingClientRect();
    const x = r.x + r.width / 2;
    const y = r.y + r.height / 2;
    const hit = document.elementFromPoint(x, y);
    toggle = { x, y, onScreen: r.right > 0 && r.left < vw, topmost: !!hit && (hit === shown || shown.contains(hit)) };
  }
  const closer = spec.close && document.querySelector(spec.close);
  const cr = closer && closer.getBoundingClientRect();
  return { state, toggle, closer: cr && cr.width > 0 ? { x: cr.x + cr.width - 5, y: cr.y + cr.height / 2 } : null };
}

async function checkViewport(browser, url, layout, [w, h]) {
  const { send, loaded } = browser;
  const results = [];
  await send('Emulation.setDeviceMetricsOverride', { width: w, height: h, deviceScaleFactor: 1, mobile: false });
  loaded.length = 0;
  await send('Page.navigate', { url });
  for (let i = 0; i < 300 && !loaded.length; i++) await sleep(100);
  if (!loaded.length) return [`FAIL ${w}x${h}: ${url} did not load in 30 s`];
  await sleep(800);
  const look = async (spec) => (await send('Runtime.evaluate', { expression: `(${probe})(${JSON.stringify(spec)})`, returnByValue: true })).result.result.value;
  const click = async ({ x, y }) => {
    for (const type of ['mouseMoved', 'mousePressed', 'mouseReleased']) await send('Input.dispatchMouseEvent', { type, x, y, button: 'left', clickCount: 1 });
    await sleep(700);
  };
  const escape = async () => {
    for (const type of ['keyDown', 'keyUp']) await send('Input.dispatchKeyEvent', { type, key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
    await sleep(700);
  };
  for (const spec of layout.sidebars) {
    const where = `${w}x${h} ${spec.name}`;
    const before = await look(spec);
    if (before.state === 'absent') { results.push(`ok   ${where}: no such sidebar on this page`); continue; }
    if (!before.toggle) {
      results.push(before.state === 'open' ? `ok   ${where}: shown, no toggle at this width` : `FAIL ${where}: hidden, and no toggle opens it`);
      continue;
    }
    const at = `toggle at ${Math.round(before.toggle.x)},${Math.round(before.toggle.y)}`;
    if (!before.toggle.onScreen) { results.push(`FAIL ${where}: the ${at} is off-screen`); continue; }
    if (!before.toggle.topmost) { results.push(`FAIL ${where}: the ${at} is covered by another element`); continue; }
    await click(before.toggle);
    const toggled = await look(spec);
    if (toggled.state === before.state) { results.push(`FAIL ${where}: clicking the ${at} leaves it ${before.state}`); continue; }
    if (toggled.closer) await click(toggled.closer);
    else if (toggled.toggle && toggled.toggle.topmost) await click(toggled.toggle);
    else await escape();
    const after = await look(spec);
    results.push(after.state === before.state
      ? `ok   ${where}: ${before.state} -> ${toggled.state} -> ${after.state} (${at})`
      : `FAIL ${where}: ${before.state} -> ${toggled.state}, and it does not go back`);
  }
  return results;
}

const isUrl = (s) => /^https?:\/\//.test(s);

// A published site answers its marker file; a built one has it on disk.
async function detect(site) {
  for (const kind of Object.keys(LAYOUTS)) {
    const marker = LAYOUTS[kind].marker;
    if (isUrl(site) ? (await fetch(new URL(marker, site), { method: 'HEAD' })).ok : fs.existsSync(path.join(site, marker))) return kind;
  }
  return null;
}

async function main() {
  const arg = process.argv[2];
  if (!arg || process.argv.length > 3) fail('usage: check-docs-sidebars.js <site dir | https URL>');
  const site = isUrl(arg) ? arg.replace(/\/?$/, '/') : path.resolve(arg);
  if (!isUrl(site) && !fs.existsSync(path.join(site, 'index.html'))) fail(`${arg} has no index.html`);
  const kind = await detect(site);
  if (!kind) { process.stdout.write(`check-docs-sidebars: ${arg} is neither a Sphinx-book nor a dartdoc site; nothing to toggle\n`); return; }
  const chrome = findChrome();
  if (!chrome) fail('no Chrome (CHROME_EXECUTABLE, chrome, chromium): the family image carries Chrome for Testing');
  const server = isUrl(site) ? null : await serve(site);
  const browser = await launch(chrome);
  const url = server ? `http://127.0.0.1:${server.address().port}/index.html` : new URL('index.html', site).href;
  // CHECK_DOCS_SIDEBARS_VIEWPORTS="WxH ...": the suite's fixtures need one width, not the theme's four.
  const custom = (process.env.CHECK_DOCS_SIDEBARS_VIEWPORTS || '').split(/\s+/).filter(Boolean).map((v) => v.split('x').map(Number));
  const lines = [];
  try {
    for (const vp of custom.length ? custom : LAYOUTS[kind].viewports) lines.push(...await checkViewport(browser, url, LAYOUTS[kind], vp));
  } finally {
    browser.close();
    if (server) server.close();
  }
  process.stdout.write(`check-docs-sidebars: ${kind} site ${arg}, ${browser.product} (${chrome})\n${lines.map((l) => `  ${l}`).join('\n')}\n`);
  const failed = lines.filter((l) => l.startsWith('FAIL')).length;
  if (failed) fail(`${failed} sidebar toggle check(s) failed; see docs/docs-sites.md#the-sidebar-toggle-check`, 1);
}

main().catch((e) => fail(e.stack || String(e)));
