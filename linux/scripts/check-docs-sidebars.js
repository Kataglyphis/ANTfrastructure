#!/usr/bin/env node
// check-docs-sidebars.js <site dir | https URL> [page ...]: click every sidebar toggle and Exhale tree view of a built Sphinx-book, dartdoc or rustdoc site in headless Chrome; any uncaught exception fails. See docs/docs-sites.md#the-sidebar-toggle-check
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
  // rustdoc's sidebar slides in from its top bar's toggle at 700 and below.
  rustdoc: {
    marker: 'crates.js',
    viewports: [[1400, 900], [700, 900], [400, 800]],
    sidebars: [{ name: 'left', sidebar: 'nav.sidebar', toggle: '.sidebar-menu-toggle' }],
  },
};

// Exhale's tree views (Kate Morley's CollapsibleLists): a built site's pages that carry one are opened too.
const TREE_MARKER = /class="[^"]*\bcollapsibleList\b/;

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

// Chrome may still write its profile after kill() returns; reaping precedes bounded filesystem retries.
async function closeChrome(ws, proc, profile, timeoutMs = 5000, kill = () => proc.kill('SIGKILL')) {
  ws.close();
  let timer, onExit;
  const exited = proc.exitCode !== null || proc.signalCode !== null
    ? Promise.resolve()
    : new Promise((resolve) => { onExit = resolve; proc.once('exit', onExit); });
  try {
    kill();
    await Promise.race([exited, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`Chrome did not exit within ${timeoutMs} ms; profile retained at ${profile}`)), timeoutMs);
    })]);
  } finally {
    clearTimeout(timer);
    if (onExit) proc.removeListener('exit', onExit);
  }
  fs.rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
}

// Every launched browser must finish cleanup even when one cleanup fails.
async function closeBrowsers(browsers) {
  const outcomes = await Promise.allSettled(browsers.splice(0).map((browser) => browser.close()));
  const failed = outcomes.find((outcome) => outcome.status === 'rejected');
  if (failed) throw failed.reason;
}

// launch(chrome, gpuFlags, onEvent): webgpu-canvas-readback.js passes SwiftShader's WebGPU flags, check-live-site.js an event sink.
async function launch(chrome, gpuFlags = ['--disable-gpu'], onEvent = null) {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'docs-sidebars-'));
  const proc = spawn(chrome, ['--headless=new', '--no-sandbox', ...gpuFlags, '--no-first-run',
    '--disable-dev-shm-usage', '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'],
  { stdio: 'ignore', detached: true });
  // Chrome's children share its process group: one group kill leaves no renderer behind.
  const killGroup = () => { try { process.kill(-proc.pid, 'SIGKILL'); } catch { /* the group is gone already */ } };
  const cleanup = () => { killGroup(); process.off('SIGINT', onSignal); process.off('SIGTERM', onSignal); fs.rmSync(profile, { recursive: true, force: true, maxRetries: 50, retryDelay: 100 }); };
  // Ctrl-C must not leave a detached browser or its profile behind.
  const onSignal = () => { try { cleanup(); } catch { /* best effort on the way out */ } process.exit(130); };
  process.once('SIGINT', onSignal);
  process.once('SIGTERM', onSignal);
  const portFile = path.join(profile, 'DevToolsActivePort');
  // Chrome creates the file before it writes the port: under load a read in between got '' and polled 127.0.0.1: for nothing.
  let port = '';
  for (let i = 0; i < 600 && !port; i++) {
    try { port = (fs.readFileSync(portFile, 'utf8').match(/^(\d+)\n/) || [])[1] || ''; } catch { port = ''; }
    if (!port) await sleep(100);
  }
  if (!port) { proc.kill('SIGKILL'); fail(`${chrome} started no DevTools endpoint in 60 s`); }
  let targets = [];
  for (let i = 0; i < 300 && !targets.some((t) => t.type === 'page'); i++) {
    try { targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json(); } catch { targets = []; }
    if (!targets.some((t) => t.type === 'page')) await sleep(100);
  }
  const page = targets.find((t) => t.type === 'page');
  if (!page) { proc.kill('SIGKILL'); fail(`${chrome} opened no page in 30 s`); }
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
  let id = 0;
  const pending = new Map();
  const loaded = [];
  const thrown = [];
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } else if (m.method === 'Page.loadEventFired') loaded.push(m);
    else if (m.method === 'Runtime.exceptionThrown') thrown.push(m.params.exceptionDetails);
    if (m.method && onEvent) onEvent(m);
  };
  // A Chrome that stops answering must fail the check, not hang the preflight: bound every call.
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const i = ++id;
    const timer = setTimeout(() => { pending.delete(i); reject(new Error(`${method} got no answer from Chrome in 30 s`)); }, 30000);
    pending.set(i, (m) => { clearTimeout(timer); resolve(m); });
    ws.send(JSON.stringify({ id: i, method, params }));
  });
  const close = async () => {
    try { await closeChrome(ws, proc, profile, 5000, killGroup); }
    finally { process.off('SIGINT', onSignal); process.off('SIGTERM', onSignal); }
  };
  const kill = killGroup;
  await send('Page.enable');
  await send('Runtime.enable');
  const product = (await send('Browser.getVersion')).result.product;
  return { send, loaded, thrown, close, kill, product };
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

// Runs in the page: the first foldable item of a tree view, its state, and a point on its own text.
function treeProbe() {
  const sublist = (li) => [...li.children].find((c) => c.tagName === 'UL');
  const items = [...document.querySelectorAll('ul.collapsibleList li')].filter(sublist);
  if (!items.length) return null;
  let li = document.querySelector('[data-check-docs-tree]');
  if (!li) {
    li = items.find((e) => /(^| )collapsibleList(Open|Closed)( |$)/.test(e.className));
    if (!li) return { applied: false };
    li.setAttribute('data-check-docs-tree', '');
  }
  // Its first line, not the whole item: an open namespace is taller than the viewport, and centring it hides its text.
  (li.querySelector(':scope > a') || li).scrollIntoView({ block: 'center' });
  // The item's own text, not its link: a click on the link navigates away.
  const text = [...li.childNodes].find((n) => n.nodeType === Node.TEXT_NODE && n.textContent.trim());
  const range = document.createRange();
  if (text) range.selectNodeContents(text);
  const box = li.getBoundingClientRect();
  const r = text ? range.getBoundingClientRect() : { x: box.x, y: box.y, width: 8, height: 16 };
  const x = r.x + r.width / 2;
  const y = r.y + r.height / 2;
  return { applied: true, state: getComputedStyle(sublist(li)).display === 'none' ? 'closed' : 'open', x, y, topmost: document.elementFromPoint(x, y) === li };
}

// An uncaught exception as one line: its message and where it was thrown.
function uncaught(details) {
  const message = (details.exception && details.exception.description) || details.text || 'exception';
  const at = details.url ? ` (${details.url.replace(/[?#].*$/, '')}:${details.lineNumber + 1}:${details.columnNumber + 1})` : '';
  return `${/in promise/.test(details.text || '') ? '(in promise) ' : ''}${message.split('\n')[0]}${at}`;
}

async function checkViewport(browser, url, layout, [w, h]) {
  const { send, loaded, thrown } = browser;
  const results = [];
  await send('Emulation.setDeviceMetricsOverride', { width: w, height: h, deviceScaleFactor: 1, mobile: false });
  loaded.length = 0;
  thrown.length = 0;
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
  const lookTree = async () => (await send('Runtime.evaluate', { expression: `(${treeProbe})()`, returnByValue: true })).result.result.value;
  const tree = await lookTree();
  if (tree) {
    const item = tree.applied ? `item at ${Math.round(tree.x)},${Math.round(tree.y)}` : '';
    if (!tree.applied) results.push(`FAIL ${w}x${h} tree: no item folds; the tree view's script did not run`);
    else if (!tree.topmost) results.push(`FAIL ${w}x${h} tree: the ${item} is covered by another element`);
    else {
      await click(tree);
      const folded = await lookTree();
      if (folded.state === tree.state) results.push(`FAIL ${w}x${h} tree: clicking the ${item} leaves it ${tree.state}`);
      else {
        await click(folded);
        const back = await lookTree();
        results.push(back.state === tree.state
          ? `ok   ${w}x${h} tree: ${tree.state} -> ${folded.state} -> ${back.state} (${item})`
          : `FAIL ${w}x${h} tree: ${tree.state} -> ${folded.state}, and it does not go back`);
      }
    }
  }
  for (const line of new Set(thrown.map(uncaught))) results.push(`FAIL ${w}x${h}: uncaught ${line}`);
  return results;
}

const isUrl = (s) => /^https?:\/\//.test(s);

// Every page of a built site with a tree view, relative to its root.
function treePages(root) {
  const found = [];
  const walk = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const file = path.join(dir, e.name);
      if (e.isDirectory()) walk(file);
      else if (e.name.endsWith('.html') && TREE_MARKER.test(fs.readFileSync(file, 'utf8'))) found.push(path.relative(root, file).split(path.sep).join('/'));
    }
  };
  walk(root);
  return found.sort();
}

// A rustdoc site's index.html is a redirect at best: the crate pages that hold guide pages and those guides, else the first crate's.
function rustdocPages(root) {
  const pages = [];
  for (const e of fs.readdirSync(root, { withFileTypes: true }).filter((d) => d.isDirectory()).sort((a, b) => a.name.localeCompare(b.name))) {
    const guides = fs.readdirSync(path.join(root, e.name)).filter((f) => /^guide-[\w-]+\.html$/.test(f)).sort();
    if (guides.length) pages.push(`${e.name}/index.html`, ...guides.map((f) => `${e.name}/${f}`));
  }
  if (pages.length) return pages;
  const crate = (fs.readFileSync(path.join(root, 'crates.js'), 'utf8').match(/"([^"/]+)"/) || [])[1];
  return crate && fs.existsSync(path.join(root, crate, 'index.html')) ? [`${crate}/index.html`] : ['index.html'];
}

// A published site answers its marker file; a built one has it on disk.
async function detect(site) {
  for (const kind of Object.keys(LAYOUTS)) {
    const marker = LAYOUTS[kind].marker;
    if (isUrl(site) ? (await fetch(new URL(marker, site), { method: 'HEAD' })).ok : fs.existsSync(path.join(site, marker))) return kind;
  }
  return null;
}

async function main() {
  const [arg, ...asked] = process.argv.slice(2);
  if (!arg) fail('usage: check-docs-sidebars.js <site dir | https URL> [page ...]');
  const site = isUrl(arg) ? arg.replace(/\/?$/, '/') : path.resolve(arg);
  if (!isUrl(site) && !fs.existsSync(path.join(site, 'index.html'))) fail(`${arg} has no index.html`);
  for (const page of asked) {
    if (!/^[\w./-]+\.html$/.test(page) || page.split('/').includes('..')) fail(`${page}: a page is a .html path under the site root`);
    if (!isUrl(site) && !fs.existsSync(path.join(site, page))) fail(`${arg} has no ${page}`);
  }
  const kind = await detect(site);
  if (!kind) { process.stdout.write(`check-docs-sidebars: ${arg} is neither a Sphinx-book, a dartdoc nor a rustdoc site; nothing to toggle\n`); return; }
  const chrome = findChrome();
  if (!chrome) fail('no Chrome (CHROME_EXECUTABLE, chrome, chromium): the family image carries Chrome for Testing');
  const start = kind === 'rustdoc' && !isUrl(site) ? rustdocPages(site) : ['index.html'];
  const pages = [...new Set([...start, ...asked, ...(kind === 'sphinx' && !isUrl(site) ? treePages(site) : [])])];
  // CHECK_DOCS_SIDEBARS_VIEWPORTS="WxH ...": the suite's fixtures need one width, not the theme's four.
  const custom = (process.env.CHECK_DOCS_SIDEBARS_VIEWPORTS || '').split(/\s+/).filter(Boolean).map((v) => v.split('x').map(Number));
  const viewports = custom.length ? custom : LAYOUTS[kind].viewports;
  const jobs = pages.flatMap((page) => viewports.map((vp) => ({ page, vp })));
  // CHECK_DOCS_SIDEBARS_JOBS: browsers at once, each taking the next page and width; 1 checks them in turn.
  const askedJobs = process.env.CHECK_DOCS_SIDEBARS_JOBS || String(Math.min(4, os.cpus().length));
  if (!/^[1-9]\d*$/.test(askedJobs)) fail(`CHECK_DOCS_SIDEBARS_JOBS=${askedJobs} is not a positive integer`);
  const server = isUrl(site) ? null : await serve(site);
  const base = server ? `http://127.0.0.1:${server.address().port}/` : site;
  const found = new Array(jobs.length);
  const browsers = [];
  let product = '';
  // fail() exits without the finally below, and an orphaned headless Chrome outlives its run.
  process.on('exit', () => { for (const b of browsers.splice(0)) b.kill(); });
  try {
    for (let i = 0; i < Math.min(Number(askedJobs), jobs.length); i++) browsers.push(await launch(chrome));
    product = browsers[0].product;
    let next = 0;
    await Promise.all(browsers.map(async (browser) => {
      while (next < jobs.length) {
        const j = next++;
        found[j] = await checkViewport(browser, new URL(jobs[j].page, base).href, LAYOUTS[kind], jobs[j].vp);
      }
    }));
  } finally {
    try { await closeBrowsers(browsers); }
    finally { if (server) server.close(); }
  }
  const lines = found.flat();
  const report = jobs.flatMap((job, j) => [...(j % viewports.length ? [] : [`  ${job.page}`]), ...found[j].map((l) => `    ${l}`)]);
  process.stdout.write(`check-docs-sidebars: ${kind} site ${arg}, ${product} (${chrome})\n${report.join('\n')}\n`);
  const failed = lines.filter((l) => l.startsWith('FAIL')).length;
  if (failed) fail(`${failed} check(s) failed; see docs/docs-sites.md#the-sidebar-toggle-check`, 1);
}

if (require.main === module) main().catch((e) => fail(e.stack || String(e)));
else module.exports = { findChrome, launch, serve, sleep, closeChrome, closeBrowsers };
