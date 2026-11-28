// ort-web-loader.mjs: picks the staged ORT Web build this browser can run and loads that build's files only. See docs/docs-sites.md#loading-ort-web-in-an-app

export const SCHEMA_VERSION = 1;
// The order of preference, as stage-ort-web.py stages them; JSEP never ships (it cannot run DEIM).
export const BUILD_ORDER = Object.freeze(['jspi', 'asyncify', 'cpu']);
// build: the prefix of its ort.*.mjs bundles and the ORT execution provider it runs.
export const BUILDS = Object.freeze({
  jspi: Object.freeze({ prefix: 'ort.jspi', provider: 'webgpu' }),
  asyncify: Object.freeze({ prefix: 'ort.webgpu', provider: 'webgpu' }),
  cpu: Object.freeze({ prefix: 'ort.wasm', provider: 'wasm' }),
});
export const REASONS = Object.freeze({
  'jspi-webgpu': 'WebAssembly JSPI exists and a WebGPU adapter answered',
  'no-jspi': 'a WebGPU adapter answered, but WebAssembly JSPI is missing',
  'no-secure-context': 'the page is not a secure context, so it has no WebGPU',
  'no-webgpu': 'the browser has no WebGPU',
  'no-adapter': 'WebGPU answered without an adapter',
  'adapter-error': 'the WebGPU adapter request failed',
  'adapter-timeout': 'the WebGPU adapter request did not answer in time',
  requested: 'the caller asked for this build',
});
// The provider name ORT's placement log uses for each execution provider.
export const PLACEMENT_NAMES = Object.freeze({ webgpu: 'WebGpuExecutionProvider', wasm: 'CPUExecutionProvider' });
const PLACEMENT = /(?:All nodes|Node\(s\)) placed on \[([A-Za-z0-9_]+)\]\. Number of nodes: (\d+)/g;
const BUILD_PATH = /^ort\/\d+\.\d+\.\d+-[0-9a-f]{16}\/$/;
const PLAIN_FILE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const SHA256 = /^[0-9a-f]{64}$/;

/** A refusal: `code` names it, `provenance` holds what was chosen before it. */
export class OrtWebLoadError extends Error {
  constructor(code, message, provenance = null) {
    super(message);
    this.name = 'OrtWebLoadError';
    this.code = code;
    this.provenance = provenance;
  }
}

function adapterInfo(adapter) {
  const info = adapter.info || {};
  return { vendor: info.vendor || '', architecture: info.architecture || '', device: info.device || '',
    description: info.description || '', is_fallback: info.isFallbackAdapter === true };
}

async function requestAdapter(gpu, scope, timeoutMs) {
  let timer;
  const late = new Promise((resolve) => { timer = scope.setTimeout(() => resolve('timeout'), timeoutMs); });
  try {
    const adapter = await Promise.race([gpu.requestAdapter(), late]);
    if (adapter === 'timeout') return { adapter: null, adapter_error: 'timeout' };
    return { adapter: adapter ? adapterInfo(adapter) : null, adapter_error: null };
  } catch (error) {
    return { adapter: null, adapter_error: String((error && error.message) || error) };
  } finally {
    scope.clearTimeout(timer);
  }
}

/** What the build choice reads: secure context, isolation, JSPI, WebGPU and its adapter. */
export async function probeCapabilities({ scope = globalThis, adapterTimeoutMs = 5000 } = {}) {
  const wasm = scope.WebAssembly || {};
  const nav = scope.navigator || {};
  const caps = { secure_context: scope.isSecureContext === true, cross_origin_isolated: scope.crossOriginIsolated === true,
    jspi: typeof wasm.Suspending === 'function' && typeof wasm.promising === 'function',
    webgpu: !!nav.gpu, adapter: null, adapter_error: null, hardware_concurrency: Number(nav.hardwareConcurrency) || 1 };
  if (caps.secure_context && caps.webgpu) Object.assign(caps, await requestAdapter(nav.gpu, scope, adapterTimeoutMs));
  return caps;
}

function choice(build, reason) {
  return { build, provider: BUILDS[build].provider, reason, reason_text: REASONS[reason] };
}

/** JSPI when JSPI exists and an adapter answers; Asyncify when only the adapter answers; CPU otherwise, with why. */
export function chooseBuild(caps, { build = null } = {}) {
  if (build !== null) {
    if (!BUILD_ORDER.includes(build)) throw new OrtWebLoadError('unknown-build', `no build ${build}: one of ${BUILD_ORDER.join(', ')}`);
    return choice(build, 'requested');
  }
  if (!caps.secure_context) return choice('cpu', 'no-secure-context');
  if (!caps.webgpu) return choice('cpu', 'no-webgpu');
  if (caps.adapter_error === 'timeout') return choice('cpu', 'adapter-timeout');
  if (caps.adapter_error) return choice('cpu', 'adapter-error');
  if (!caps.adapter) return choice('cpu', 'no-adapter');
  return caps.jspi ? choice('jspi', 'jspi-webgpu') : choice('asyncify', 'no-jspi');
}

/** ORT's own default: up to four threads when isolated, one otherwise, since threads need SharedArrayBuffer. */
export function threadCount(caps, requested = null) {
  if (!caps.cross_origin_isolated) return { threads: 1, threads_note: 'not-isolated' };
  const threads = requested ?? Math.min(4, Math.ceil(caps.hardware_concurrency / 2));
  return { threads, threads_note: null };
}

function oneFile(entry, role, names = null) {
  const files = entry.files.filter((f) => f.role === role && (names === null || names.includes(f.file)));
  if (names !== null) files.sort((a, b) => names.indexOf(a.file) - names.indexOf(b.file));
  else if (files.length !== 1) throw new OrtWebLoadError('bad-manifest', `build ${entry.build}: ${files.length} ${role} files, not one`);
  return files[0] || null;
}

/** One build's entry in stage-ort-web.py's manifest, with its bundle, loader and wasm picked out. */
export function buildEntry(manifest, build) {
  if (!manifest || manifest.schema_version !== SCHEMA_VERSION || !Array.isArray(manifest.builds)) {
    throw new OrtWebLoadError('bad-manifest', 'not a schema 1 ORT Web manifest');
  }
  const entry = manifest.builds.find((b) => b && b.build === build);
  if (!entry) throw new OrtWebLoadError('build-not-staged', `build ${build} is not staged`);
  if (!BUILD_PATH.test(entry.path || '') || !Array.isArray(entry.files)) {
    throw new OrtWebLoadError('bad-manifest', `build ${build}: path ${entry.path} is not ort/<version>-<build hash>/`);
  }
  for (const f of entry.files) {
    if (!PLAIN_FILE.test(f.file || '') || !SHA256.test(f.sha256 || '')) throw new OrtWebLoadError('bad-manifest', `build ${build}: file ${f.file} has no plain name or sha256`);
  }
  const { prefix } = BUILDS[build];
  // The minified bundle imports the loader beside it; the bundle.min one carries a copy of it inside.
  const bundle = oneFile(entry, 'bundle', [`${prefix}.min.mjs`, `${prefix}.mjs`, `${prefix}.bundle.min.mjs`]);
  if (!bundle) throw new OrtWebLoadError('no-bundle', `build ${build}: no ${prefix}*.mjs bundle staged (the image builds them on amd64 only)`);
  return { build, path: entry.path, build_hash: entry.build_hash, bundle, loader: oneFile(entry, 'loader'), wasm: oneFile(entry, 'wasm') };
}

function hex(buffer) {
  return Array.from(new Uint8Array(buffer), (b) => b.toString(16).padStart(2, '0')).join('');
}

async function fetchChecked(fetchFn, subtle, url, item, provenance) {
  const response = await fetchFn(url);
  if (!response.ok) throw new OrtWebLoadError('fetch-failed', `${url}: HTTP ${response.status}`, provenance);
  const bytes = await response.arrayBuffer();
  if (subtle) {
    const actual = hex(await subtle.digest('SHA-256', bytes));
    if (actual !== item.sha256) throw new OrtWebLoadError('hash-mismatch', `${url}: sha256 ${actual}, the manifest says ${item.sha256}`, provenance);
  }
  return bytes;
}

async function readManifest(fetchFn, url) {
  const response = await fetchFn(url, { cache: 'no-cache' });
  if (!response.ok) throw new OrtWebLoadError('fetch-failed', `${url}: HTTP ${response.status}`);
  try { return await response.json(); } catch { throw new OrtWebLoadError('bad-manifest', `${url} is not JSON`); }
}

function fileRecord(item) {
  return { file: item.file, sha256: item.sha256, size: item.size ?? null };
}

/** The build this browser gets and why, from the manifest alone: nothing of the build is fetched yet. */
export async function planOrtWeb({ base = null, manifest = null, build = null, threads = null, capabilities = null,
  scope = globalThis, fetch: fetchFn = (...a) => scope.fetch(...a) } = {}) {
  const root = new URL(base ?? './', scope.location && scope.location.href);
  const manifestUrl = new URL('ort/manifest.json', root).href;
  const caps = capabilities ?? await probeCapabilities({ scope });
  const chosen = chooseBuild(caps, { build });
  const staged = manifest ?? await readManifest(fetchFn, manifestUrl);
  const entry = buildEntry(staged, chosen.build);
  const provenance = { schema_version: SCHEMA_VERSION, ...chosen, build_hash: entry.build_hash, path: entry.path,
    ort_version: staged.ort && staged.ort.version, ort_revision: staged.ort && staged.ort.revision, ort_web: null,
    files: { bundle: fileRecord(entry.bundle), loader: fileRecord(entry.loader), wasm: fileRecord(entry.wasm) },
    verified: false, ...threadCount(caps, threads), capabilities: caps,
    manifest: { url: manifestUrl, image_receipt_sha256: (staged.image_receipt && staged.image_receipt.sha256) || null } };
  return { provenance, entry, root };
}

/** Plans, checks the build's bundle, loader and wasm against the manifest, imports the bundle and points ORT at that build alone. */
export async function loadOrtWeb({ verify = true, scope = globalThis, fetch: fetchFn = (...a) => scope.fetch(...a),
  importModule = (url) => import(url), ...options } = {}) {
  const { provenance, entry, root } = await planOrtWeb({ ...options, scope, fetch: fetchFn });
  const subtle = scope.crypto && scope.crypto.subtle;
  if (verify && !subtle) throw new OrtWebLoadError('unverifiable', 'no crypto.subtle (it needs a secure context): the ORT files cannot be checked', provenance);
  const at = (item) => new URL(entry.path + item.file, root).href;
  const [, , wasmBytes] = await Promise.all([entry.bundle, entry.loader, entry.wasm]
    .map((item) => fetchChecked(fetchFn, verify ? subtle : null, at(item), item, provenance)));
  provenance.verified = verify;
  if (scope.console) consoleTap(scope);
  const ort = await importModule(at(entry.bundle));
  provenance.ort_web = (ort.env && ort.env.versions && ort.env.versions.web) || null;
  if (provenance.ort_web !== provenance.ort_version) {
    throw new OrtWebLoadError('version-mismatch', `the bundle is ORT ${provenance.ort_web}, the manifest's build ${provenance.ort_version}`, provenance);
  }
  // The checked bytes go to ORT, and both paths name this build, so no other build's loader or wasm can load.
  Object.assign(ort.env.wasm, { wasmPaths: { mjs: at(entry.loader), wasm: at(entry.wasm) }, wasmBinary: new Uint8Array(wasmBytes),
    numThreads: provenance.threads, proxy: false });
  return { ort, provenance, executionProviders: [provenance.provider] };
}

/** Nodes per provider from ORT's verbose placement lines of one session. */
export function countPlacements(lines) {
  const counts = {};
  for (const line of lines) {
    for (const [, provider, nodes] of String(line).matchAll(PLACEMENT)) counts[provider] = (counts[provider] || 0) + Number(nodes);
  }
  return counts;
}

// ORT's glue binds console.log and console.error once when it loads, so the tap goes in before it and stays.
const TAP = Symbol.for('ort-web-loader.console-tap');

function consoleTap(scope) {
  const con = scope.console;
  if (!con[TAP]) {
    const tap = { lines: null, queue: Promise.resolve() };
    for (const method of ['log', 'info', 'warn', 'error', 'debug']) {
      const original = con[method];
      con[method] = (...args) => {
        if (tap.lines) tap.lines.push(args.map(String).join(' '));
        return original.apply(con, args);
      };
    }
    con[TAP] = tap;
  }
  return con[TAP];
}

async function createLogged(tap, ort, model, options) {
  const lines = [];
  tap.lines = lines;
  try {
    return { session: await ort.InferenceSession.create(model, { ...options, logSeverityLevel: 0, logVerbosityLevel: 0 }), lines };
  } finally {
    tap.lines = null;
  }
}

/** A session on the loaded build; ORT's placement lines say which provider ran each node, since it moves nodes to the CPU without a word. */
export async function createSession(loaded, model, { options = {}, scope = globalThis } = {}) {
  const { ort, provenance, executionProviders } = loaded;
  const tap = consoleTap(scope);
  // One session at a time: a second one's placement lines would land in the first one's count.
  const run = tap.queue.then(() => createLogged(tap, ort, model, { ...options, executionProviders }));
  tap.queue = run.catch(() => {});
  const { session, lines } = await run;
  const counts = countPlacements(lines);
  const total = Object.values(counts).reduce((a, b) => a + b, 0);
  const onProvider = counts[PLACEMENT_NAMES[provenance.provider]] || 0;
  provenance.session = { placements: counts, nodes: total, on_provider: onProvider,
    share: total ? onProvider / total : 0, proven: onProvider > 0 };
  return session;
}
