#!/usr/bin/env node
// ort-web-detector-parity.js --site DIR --module REL --wasm-dir REL --ep webgpu|wasm --gpu webgpu|none --model FILE --input FILE --out FILE: run one staged ORT Web build in headless Chrome. See docs/docs-sites.md#detector-parity-of-the-ort-web-builds
'use strict';

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { findChrome, launch, sleep } = require('./check-docs-sidebars.js');
const { WEBGPU_FLAGS } = require('./webgpu-canvas-readback.js');

const TYPES = { '.mjs': 'text/javascript', '.js': 'text/javascript', '.wasm': 'application/wasm', '.json': 'application/json' };
// COOP and COEP make the page cross-origin isolated: the threaded builds need SharedArrayBuffer.
const ISOLATION = { 'Cross-Origin-Opener-Policy': 'same-origin', 'Cross-Origin-Embedder-Policy': 'require-corp',
  'Cross-Origin-Resource-Policy': 'same-origin', 'Cache-Control': 'no-store' };
const PAGE = '<!doctype html><meta charset="utf-8"><title>ORT Web detector parity</title>';
const OPTIONS = { '--site': 'site', '--module': 'module', '--wasm-dir': 'wasmDir', '--ep': 'ep', '--gpu': 'gpu', '--model': 'model',
  '--input': 'input', '--out': 'out', '--js-dir': 'jsDir', '--runs': 'runs', '--threads': 'threads', '--timeout-ms': 'timeoutMs' };

function fail(message, code = 2) {
  process.stderr.write(`ort-web-detector-parity: ${message}\n`);
  process.exit(code);
}

/** --flag value pairs over defaults; a switch stands alone, numbers become Numbers and required ones must be set. */
function readOptions(argv, { defaults, options, switches = {}, numbers = [], required = [] }) {
  const opts = { ...defaults };
  for (let i = 0; i < argv.length; i += 2) {
    if (switches[argv[i]]) { opts[switches[argv[i]]] = true; i -= 1; continue; }
    const key = options[argv[i]];
    if (!key) throw new Error(`unknown option ${argv[i]}`);
    if (i + 1 >= argv.length) throw new Error(`${argv[i]} needs a value`);
    opts[key] = numbers.includes(key) ? Number(argv[i + 1]) : argv[i + 1];
  }
  for (const key of required) {
    if (!opts[key]) throw new Error(`--${key.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)} is required`);
  }
  return opts;
}

function parseArgs(argv) {
  const opts = readOptions(argv, { defaults: { jsDir: '', runs: 2, threads: 2, timeoutMs: 900000 }, options: OPTIONS,
    numbers: ['runs', 'threads', 'timeoutMs'], required: ['site', 'module', 'wasmDir', 'ep', 'gpu', 'model', 'input', 'out'] });
  if (!['webgpu', 'wasm'].includes(opts.ep)) throw new Error(`--ep is webgpu or wasm, not ${opts.ep}`);
  if (!['webgpu', 'none'].includes(opts.gpu)) throw new Error(`--gpu is webgpu or none, not ${opts.gpu}`);
  for (const key of ['runs', 'threads', 'timeoutMs']) {
    if (!Number.isInteger(opts[key]) || opts[key] < 1) throw new Error(`--${key} takes a positive integer`);
  }
  return opts;
}

// A file below root, or null: no path outside it is served, whatever the URL says.
function within(root, rel) {
  const base = path.resolve(root);
  const file = path.resolve(base, `.${path.sep}${rel}`);
  return file.startsWith(base + path.sep) ? file : null;
}

// The page, the site's ort/ tree, the model, the input tensor and an optional JS layer, every answer isolated.
function route(opts, pathname) {
  if (pathname === '/') return { body: PAGE, type: 'text/html' };
  if (pathname === '/model.onnx') return { file: opts.model };
  if (pathname === '/input.bin') return { file: opts.input };
  for (const [prefix, root] of [['/site/', opts.site], ['/js/', opts.jsDir]]) {
    if (root && pathname.startsWith(prefix)) {
      const file = within(root, pathname.slice(prefix.length));
      return file ? { file } : null;
    }
  }
  return null;
}

/** A loopback server on a free port: router(pathname) gives { body, type }, { file } or null; every reply carries headers. */
function serveRoutes(router, headers) {
  const server = http.createServer((req, res) => {
    let found;
    try { found = router(decodeURIComponent(new URL(req.url, 'http://x').pathname)); } catch { found = null; }
    if (found && found.body) { res.writeHead(200, { ...headers, 'Content-Type': found.type }).end(found.body); return; }
    if (!found) { res.writeHead(404, headers).end(); return; }
    fs.readFile(found.file, (err, body) => {
      if (err) { res.writeHead(404, headers).end(); return; }
      res.writeHead(200, { ...headers, 'Content-Type': TYPES[path.extname(found.file)] || 'application/octet-stream' }).end(body);
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

function serve(opts) {
  return serveRoutes((pathname) => route(opts, pathname), ISOLATION);
}

// Runs in the page: one session on the build, the same input `runs` times; output0's bytes go back as base64.
async function runInPage(o) {
  const at = (p) => new URL(p, o.base).href;
  const result = { crossOriginIsolated: globalThis.crossOriginIsolated === true, jspi: typeof WebAssembly.Suspending === 'function',
    webgpu: typeof navigator !== 'undefined' && !!navigator.gpu, adapter: null, runs: [], error: null };
  const b64 = (bytes) => { let s = ''; for (let i = 0; i < bytes.length; i += 32768) s += String.fromCharCode(...bytes.subarray(i, i + 32768)); return btoa(s); };
  try {
    if (result.webgpu) {
      const adapter = await navigator.gpu.requestAdapter();
      const info = adapter && adapter.info;
      result.adapter = info ? { vendor: info.vendor, architecture: info.architecture, device: info.device, description: info.description } : null;
    }
    const ort = await import(at(o.module));
    result.ortVersion = (ort.env.versions && ort.env.versions.web) || null;
    Object.assign(ort.env.wasm, { wasmPaths: at(o.wasmDir), numThreads: o.threads, proxy: false });
    ort.env.logLevel = 'verbose';
    const [model, input] = await Promise.all(['/model.onnx', '/input.bin'].map(async (p) => {
      const response = await fetch(at(p));
      if (!response.ok) throw new Error(`${p}: HTTP ${response.status}`);
      return response.arrayBuffer();
    }));
    let started = performance.now();
    // Verbose logs name the provider of every node, which ORT moves to the CPU without a word.
    const session = await ort.InferenceSession.create(new Uint8Array(model), { executionProviders: [o.ep], logSeverityLevel: 0, logVerbosityLevel: 0 });
    result.createMs = performance.now() - started;
    result.inputNames = session.inputNames;
    result.outputNames = session.outputNames;
    const tensor = new ort.Tensor('float32', new Float32Array(input), [1, 3, 640, 640]);
    for (let i = 0; i < o.runs; i++) {
      started = performance.now();
      const out = (await session.run({ [session.inputNames[0]]: tensor })).output0;
      if (!out) throw new Error(`the model has no output0: ${session.outputNames.join(', ')}`);
      const data = await out.getData();
      result.runs.push({ ms: performance.now() - started, dims: Array.from(out.dims), type: out.type,
        data: b64(new Uint8Array(data.buffer, data.byteOffset, data.byteLength)) });
    }
    await session.release();
  } catch (error) {
    result.error = String((error && error.stack) || error);
  }
  return result;
}

// A console line as Chrome reports it: the text of each argument, joined.
function consoleLine(params) {
  return (params.args || []).map((a) => (a.value !== undefined ? String(a.value) : a.description || '')).join(' ');
}

async function main() {
  let opts;
  try { opts = parseArgs(process.argv.slice(2)); } catch (error) { fail(error.message); }
  for (const key of ['site', 'model', 'input']) if (!fs.existsSync(opts[key])) fail(`${opts[key]} does not exist`);
  const chrome = findChrome();
  if (!chrome) fail('no Chrome (CHROME_EXECUTABLE, chrome, chromium): the family image carries Chrome for Testing');
  const server = await serve(opts);
  const base = `http://127.0.0.1:${server.address().port}/`;
  const logs = [];
  const onEvent = (m) => {
    if (m.method === 'Runtime.consoleAPICalled') logs.push(consoleLine(m.params));
    else if (m.method === 'Runtime.exceptionThrown') logs.push(`uncaught: ${m.params.exceptionDetails.text}`);
  };
  const flags = opts.gpu === 'webgpu' ? [...WEBGPU_FLAGS] : ['--disable-gpu'];
  let browser;
  let page;
  try {
    browser = await launch(chrome, flags, onEvent);
    await browser.send('Page.navigate', { url: base });
    for (let i = 0; i < 300 && !browser.loaded.length; i++) await sleep(100);
    const args = { base, module: opts.module, wasmDir: opts.wasmDir, ep: opts.ep, threads: opts.threads, runs: opts.runs };
    const answer = await browser.send('Runtime.evaluate', { expression: `(${runInPage})(${JSON.stringify(args)})`, awaitPromise: true, returnByValue: true }, opts.timeoutMs);
    page = (answer.result && answer.result.result && answer.result.result.value) || { error: `the page returned nothing: ${JSON.stringify(answer.result || answer.error)}` };
  } finally {
    try { if (browser) await browser.close(); } finally { server.close(); }
  }
  const report = { chrome: browser.product, flags, ep: opts.ep, module: opts.module, threads: opts.threads, ...page, logs };
  fs.writeFileSync(opts.out, `${JSON.stringify(report)}\n`);
  process.stdout.write(`ort-web-detector-parity: ${opts.module} on ${opts.ep}: ${page.runs ? page.runs.length : 0} run(s)${page.error ? `, error: ${page.error.split('\n')[0]}` : ''}\n`);
}

if (require.main === module) main().catch((e) => fail(e.stack || String(e)));
else module.exports = { parseArgs, readOptions, route, serve, serveRoutes, runInPage, consoleLine, within, TYPES, ISOLATION };
