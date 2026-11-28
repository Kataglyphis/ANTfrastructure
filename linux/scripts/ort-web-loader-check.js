#!/usr/bin/env node
// ort-web-loader-check.js --site DIR --case NAME [--in page|worker | --worker REL [--build NAME] [--image FILE --threshold T]] [--fake-ort] [--loader FILE] [--model FILE --input-dims 1,3,640,640 --runs N] --out FILE: the ORT Web loader in headless Chrome under one browser condition. See docs/docs-sites.md#loading-ort-web-in-an-app
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { findChrome, launch, sleep } = require('./check-docs-sidebars.js');
const { WEBGPU_FLAGS } = require('./webgpu-canvas-readback.js');
const { within, consoleLine, readOptions, serveRoutes, TYPES, ISOLATION } = require('./ort-web-detector-parity.js');

const LOADER = path.join(__dirname, '..', '..', 'shared', 'web', 'javascript', 'ort-web-loader.mjs');
const INSECURE_HOST = 'insecure.test';
// No Chrome 156+ flag turns JSPI off or removes navigator.gpu, so those two cases hide them where the loader runs.
const CASES = Object.freeze({
  jspi: { flags: WEBGPU_FLAGS, isolated: true, hide: [] },
  asyncify: { flags: WEBGPU_FLAGS, isolated: true, hide: ['jspi'] },
  'no-adapter': { flags: ['--disable-gpu'], isolated: true, hide: [] },
  'no-webgpu': { flags: WEBGPU_FLAGS, isolated: true, hide: ['webgpu'] },
  insecure: { flags: [...WEBGPU_FLAGS, `--host-resolver-rules=MAP ${INSECURE_HOST} 127.0.0.1`], isolated: true, host: INSECURE_HOST, hide: [] },
  'not-isolated': { flags: WEBGPU_FLAGS, isolated: false, hide: [] },
});
const OPTIONS = { '--site': 'site', '--case': 'case', '--in': 'in', '--worker': 'worker', '--loader': 'loader', '--model': 'model',
  '--input-dims': 'inputDims', '--runs': 'runs', '--out': 'out', '--timeout-ms': 'timeoutMs', '--build': 'build', '--image': 'image',
  '--threshold': 'threshold' };
const SWITCHES = { '--fake-ort': 'fakeOrt' };
// build: its wasm and loader stem, its bundle and the provider its fake session places nodes on.
const FAKE_BUILDS = { jspi: ['ort-wasm-simd-threaded.jspi', 'ort.jspi', 'WebGpuExecutionProvider'],
  asyncify: ['ort-wasm-simd-threaded.asyncify', 'ort.webgpu', 'WebGpuExecutionProvider'], cpu: ['ort-wasm-simd-threaded', 'ort.wasm', 'CPUExecutionProvider'] };

function fail(message, code = 2) {
  process.stderr.write(`ort-web-loader-check: ${message}\n`);
  process.exit(code);
}

function parseArgs(argv) {
  const opts = readOptions(argv, { defaults: { in: 'page', worker: '', fakeOrt: false, loader: LOADER, model: '', inputDims: '1,3,640,640',
    runs: 1, timeoutMs: 900000, build: '', image: '', threshold: 0.25 }, options: OPTIONS, switches: SWITCHES,
    numbers: ['runs', 'timeoutMs', 'threshold'], required: ['site', 'case', 'out'] });
  if (!CASES[opts.case]) throw new Error(`--case is one of ${Object.keys(CASES).join(', ')}, not ${opts.case}`);
  if (!['page', 'worker'].includes(opts.in)) throw new Error(`--in is page or worker, not ${opts.in}`);
  if (opts.worker && (opts.model || opts.in !== 'page')) throw new Error('--worker runs the app\'s own worker: no --model or --in with it');
  if ((opts.build || opts.image) && !opts.worker) throw new Error('--build and --image speak to the app\'s worker: give --worker');
  if (!(opts.threshold >= 0 && opts.threshold <= 1)) throw new Error(`--threshold is between 0 and 1, not ${opts.threshold}`);
  if (!Number.isInteger(opts.runs) || opts.runs < 0) throw new Error('--runs takes 0 (a session only) or more');
  if (!Number.isInteger(opts.timeoutMs) || opts.timeoutMs < 1) throw new Error('--timeout-ms takes a positive integer');
  opts.dims = opts.inputDims.split(',').map(Number);
  if (!opts.dims.every((d) => Number.isInteger(d) && d > 0)) throw new Error(`--input-dims takes positive integers, not ${opts.inputDims}`);
  return opts;
}

// Runs in the page or the worker: the loader, then an optional session and runs on a zero tensor.
async function runLoader(o) {
  const out = { provenance: null, error: null, runs: [], scope: typeof window === 'undefined' ? 'worker' : 'page' };
  try {
    for (const what of o.hide) {
      if (what === 'jspi') delete WebAssembly.Suspending;
      else if (what === 'webgpu') delete Object.getPrototypeOf(navigator).gpu;
    }
    const loader = await import(o.loader);
    const loaded = await loader.loadOrtWeb({ base: o.base });
    out.provenance = loaded.provenance;
    if (o.model) {
      const response = await fetch(o.model);
      const session = await loader.createSession(loaded, new Uint8Array(await response.arrayBuffer()));
      const size = o.dims.reduce((a, b) => a * b, 1);
      for (let i = 0; i < o.runs; i++) {
        const started = performance.now();
        const result = await session.run({ [session.inputNames[0]]: new loaded.ort.Tensor('float32', new Float32Array(size), o.dims) });
        out.runs.push({ ms: performance.now() - started, outputs: Object.keys(result) });
      }
      await session.release();
    }
  } catch (error) {
    out.error = { name: error && error.name, code: (error && error.code) || null, message: String((error && error.message) || error) };
    if (error && error.provenance) out.provenance = error.provenance;
  }
  return out;
}

// A stand-in for stage-ort-web.py's ort/: every build's files with their real hashes, each bundle a fake ORT module.
function fakeOrt(version = '1.31.1') {
  const files = {};
  const sha = (body) => crypto.createHash('sha256').update(body).digest('hex');
  const builds = Object.entries(FAKE_BUILDS).map(([build, [stem, prefix, placed]], i) => {
    const dir = `${version}-${String(i + 1).repeat(16)}`;
    const bundle = `export const env = { wasm: {}, versions: { web: '${version}' } };
export class Tensor { constructor(type, data, dims) { Object.assign(this, { type, data, dims }); } }
export const InferenceSession = { async create() { console.error('Node(s) placed on [${placed}]. Number of nodes: 1');
  return { inputNames: ['input'], outputNames: ['output'], async run() { return { output: {} }; }, async release() {} }; } };\n`;
    const list = [[`${stem}.wasm`, 'wasm', `fake ${build} wasm`], [`${stem}.mjs`, 'loader', `// fake ${build} loader\n`], [`${prefix}.min.mjs`, 'bundle', bundle]];
    for (const [file, , body] of list) files[`${dir}/${file}`] = body;
    return { build, path: `ort/${dir}/`, build_hash: String(i + 1).repeat(16),
      files: list.map(([file, role, body]) => ({ file, role, sha256: sha(body), size: Buffer.byteLength(body) })) };
  });
  files['manifest.json'] = JSON.stringify({ schema_version: 1, ort: { version, revision: '0'.repeat(40) }, image_receipt: null, builds });
  return files;
}

// Runs in the page: the app's own worker, asked to plan, to load and, with an image, to detect, as its page would.
function appWorker(o) {
  return new Promise((resolve) => {
    const worker = new Worker(o.worker, { type: 'module' });
    const steps = {};
    const request = (id, op) => JSON.stringify({ id, op, ...(o.build ? { build: o.build } : {}), ...(op === 'detect' ? { threshold: o.threshold } : {}) });
    const ask = (id, op) => worker.postMessage(request(id, op));
    const done = (reply) => resolve({ steps, provenance: reply.provenance || steps.plan.provenance, error: reply.ok ? null : reply.error, runs: [], scope: 'worker' });
    worker.onmessage = async (m) => {
      const reply = JSON.parse(m.data);
      if (reply.id === 1) { steps.plan = reply; ask(2, 'load'); return; }
      if (reply.id === 2) {
        steps.load = reply;
        if (!o.image || !reply.ok) { done(reply); return; }
        // The image file goes over as its bytes, transferred, beside the JSON request.
        const image = await (await fetch(o.image)).arrayBuffer();
        worker.postMessage({ request: request(3, 'detect'), image }, [image]);
        return;
      }
      steps.detect = reply;
      done(reply);
    };
    worker.onerror = (e) => resolve({ steps, error: { name: 'WorkerError', code: null, message: e.message || 'the worker failed to start' } });
    ask(1, 'plan');
  });
}

const WORKER = `const runLoader = ${runLoader};\nonmessage = async (m) => postMessage(await runLoader(m.data));\n`;
// Hides what ?hide= names in a worker scope, then imports the app's worker given as ?worker=.
const HIDE = `const early = [];
self.onmessage = (m) => early.push(m);
const params = new URL(location.href).searchParams;
for (const what of params.get('hide').split(',')) {
  if (what === 'jspi') delete WebAssembly.Suspending;
  else if (what === 'webgpu') delete Object.getPrototypeOf(navigator).gpu;
}
await import(params.get('worker'));
// Messages that came during the import go to the handler the app's worker set.
for (const m of early) self.onmessage(m);
`;

// Runs in the page: in a module worker, the same function and arguments.
function inWorker(o) {
  return new Promise((resolve) => {
    const worker = new Worker('/worker.mjs', { type: 'module' });
    worker.onmessage = (m) => resolve(m.data);
    worker.onerror = (e) => resolve({ error: { name: 'WorkerError', code: null, message: e.message || 'the worker failed to start' } });
    worker.postMessage(o);
  });
}

function route(opts, pathname) {
  if (pathname === '/') return { body: '<!doctype html><meta charset="utf-8"><title>ORT Web loader check</title>', type: 'text/html' };
  if (pathname === '/worker.mjs') return { body: WORKER, type: 'text/javascript' };
  if (pathname === '/hide.mjs') return { body: HIDE, type: 'text/javascript' };
  if (pathname === '/ort-web-loader.mjs') return { file: opts.loader };
  if (pathname === '/model.onnx' && opts.model) return { file: opts.model };
  if (pathname === '/image' && opts.image) return { file: opts.image };
  if (opts.fakeOrt && pathname.startsWith('/site/ort/')) {
    const body = opts.fake[pathname.slice('/site/ort/'.length)];
    return body === undefined ? null : { body, type: TYPES[path.extname(pathname)] || 'application/octet-stream' };
  }
  if (pathname.startsWith('/site/')) {
    const file = within(opts.site, pathname.slice('/site/'.length));
    return file ? { file } : null;
  }
  return null;
}

function serve(opts) {
  const headers = { ...ISOLATION };
  // Without COOP and COEP the page is not cross-origin isolated, and ORT runs one thread.
  if (!CASES[opts.case].isolated) for (const name of ['Cross-Origin-Opener-Policy', 'Cross-Origin-Embedder-Policy']) delete headers[name];
  return serveRoutes((pathname) => route(opts, pathname), headers);
}

async function main() {
  let opts;
  try { opts = parseArgs(process.argv.slice(2)); } catch (error) { fail(error.message); }
  for (const file of [opts.site, opts.loader, ...[opts.model, opts.image].filter(Boolean)]) if (!fs.existsSync(file)) fail(`${file} does not exist`);
  const chrome = findChrome();
  if (!chrome) fail('no Chrome (CHROME_EXECUTABLE, chrome, chromium): the family image carries Chrome for Testing');
  const spec = CASES[opts.case];
  if (opts.fakeOrt) opts.fake = fakeOrt();
  const server = await serve(opts);
  const origin = `http://${spec.host || '127.0.0.1'}:${server.address().port}`;
  const logs = [];
  const onEvent = (m) => { if (m.method === 'Runtime.consoleAPICalled') logs.push(consoleLine(m.params)); };
  const args = { loader: `${origin}/ort-web-loader.mjs`, base: `${origin}/site/`, model: opts.model ? `${origin}/model.onnx` : '',
    dims: opts.dims, runs: opts.runs, hide: spec.hide, worker: '', build: opts.build, threshold: opts.threshold,
    image: opts.image ? `${origin}/image` : '' };
  if (opts.worker) {
    const own = `${origin}/site/${opts.worker}`;
    args.worker = spec.hide.length ? `${origin}/hide.mjs?hide=${spec.hide.join(',')}&worker=${encodeURIComponent(own)}` : own;
  }
  let browser;
  let answer;
  try {
    browser = await launch(chrome, [...spec.flags], onEvent);
    await browser.send('Page.navigate', { url: `${origin}/` });
    for (let i = 0; i < 300 && !browser.loaded.length; i++) await sleep(100);
    const run = opts.worker ? appWorker : opts.in === 'worker' ? inWorker : runLoader;
    const call = `(${run})(${JSON.stringify(args)})`;
    const reply = await browser.send('Runtime.evaluate', { expression: call, awaitPromise: true, returnByValue: true }, opts.timeoutMs);
    answer = (reply.result && reply.result.result && reply.result.result.value)
      || { error: { name: 'NoAnswer', code: null, message: JSON.stringify(reply.result || reply.error) } };
  } finally {
    try { if (browser) await browser.close(); } finally { server.close(); }
  }
  const report = { case: opts.case, in: opts.worker ? `worker ${opts.worker}` : opts.in, fake_ort: opts.fakeOrt, chrome: browser.product, flags: [...spec.flags], origin, ...answer, logs };
  fs.writeFileSync(opts.out, `${JSON.stringify(report, null, 1)}\n`);
  const p = answer.provenance || {};
  process.stdout.write(`ort-web-loader-check: ${opts.case} in the ${opts.worker ? 'app worker' : opts.in}: ${p.build || 'no build'} (${p.reason || 'no reason'})`
    + `${answer.error ? `, refused: ${answer.error.code || answer.error.name}: ${answer.error.message}` : ''}\n`);
}

if (require.main === module) main().catch((e) => fail(e.stack || String(e)));
else module.exports = { CASES, parseArgs, route, serve, runLoader, fakeOrt };
