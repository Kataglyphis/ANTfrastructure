#!/usr/bin/env bash
# The ORT Web loader and its Chrome check in node against fakes: the build choice, manifest reading, file checks, session placements, the check's arguments, stand-in and server. See docs/docs-sites.md#loading-ort-web-in-an-app
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LOADER="${TESTS_DIR}/../../../shared/web/javascript/ort-web-loader.mjs"
CHECK="${TESTS_DIR}/../ort-web-loader-check.js"
t_private_tmpdir
w="$(t_mktemp -d)"

t_skip_unless "node with WebCrypto (19 and later)" node -e 'process.exit(globalThis.crypto && crypto.subtle ? 0 : 1)'

cat > "${w}/loader.test.mjs" <<'EOF'
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { mkdirSync, writeFileSync } from 'node:fs';
const [loaderPath, checkPath, dir, scenario] = process.argv.slice(2);
const L = await import(loaderPath);
const check = createRequire(import.meta.url)(checkPath);
const { assertServes } = createRequire(checkPath)('./tests/serve-assert.js');
const base = ['--site', dir, '--case', 'jspi', '--out', 'x.json'];
const ADAPTER = { info: { vendor: 'google', architecture: 'swiftshader', device: '', description: 'SwiftShader' } };
const sha = (text) => createHash('sha256').update(text).digest('hex');
const STEMS = { jspi: ['ort-wasm-simd-threaded.jspi', 'ort.jspi'], asyncify: ['ort-wasm-simd-threaded.asyncify', 'ort.webgpu'], cpu: ['ort-wasm-simd-threaded', 'ort.wasm'] };

// A staged site as stage-ort-web.py writes it: one directory per build, every file with its hash.
function site({ bundles = ['min.mjs', 'mjs', 'bundle.min.mjs'], builds = Object.keys(STEMS) } = {}) {
  const files = {};
  const entries = builds.map((build, i) => {
    const [stem, prefix] = STEMS[build];
    const path = `ort/1.31.1-${String(i).repeat(16)}/`;
    const list = [[`${stem}.wasm`, 'wasm'], [`${stem}.mjs`, 'loader'], ['LICENSE', 'license'], ...bundles.map((b) => [`${prefix}.${b}`, 'bundle'])];
    return { build, path, build_hash: String(i).repeat(16), files: list.map(([file, role]) => {
      files[path + file] = `${build}:${file}`;
      return { file, role, sha256: sha(files[path + file]), size: files[path + file].length };
    }) };
  });
  const manifest = { schema_version: 1, ort: { version: '1.31.1', revision: 'a'.repeat(40) }, image_receipt: { sha256: 'b'.repeat(64) }, builds: entries };
  files['ort/manifest.json'] = JSON.stringify(manifest);
  return { files, manifest };
}

function scope({ secure = true, isolated = true, jspi = true, gpu = 'adapter', subtle = true, cores = 8 } = {}) {
  const calls = [];
  const requestAdapter = async () => {
    calls.push('requestAdapter');
    if (gpu === 'throws') throw new Error('device lost');
    if (gpu === 'hangs') return new Promise(() => {});
    return gpu === 'adapter' ? ADAPTER : null;
  };
  const lines = [];
  return { calls, lines, isSecureContext: secure, crossOriginIsolated: isolated,
    WebAssembly: jspi === true ? { Suspending: function () {}, promising: function () {} } : jspi === 'half' ? { Suspending: function () {} } : {},
    navigator: { hardwareConcurrency: cores, gpu: gpu === 'none' ? undefined : { requestAdapter } },
    setTimeout: (f, ms) => setTimeout(f, gpu === 'hangs' ? 0 : ms), clearTimeout,
    crypto: subtle ? globalThis.crypto : {}, location: { href: 'https://example.test/app/index.html' },
    console: { log: (...a) => lines.push(['log', ...a]), info() {}, warn() {}, error: (...a) => lines.push(['error', ...a]), debug() {} } };
}

// fetch over the fixture site, recording each URL; serve() changes what one path answers.
function fetcher(files, serve = {}) {
  const urls = [];
  const fetch = async (url) => {
    urls.push(url);
    const rel = new URL(url).pathname.replace(/^\/app\//, '');
    const body = rel in serve ? serve[rel] : files[rel];
    if (body === undefined || body === 404) return { ok: false, status: 404 };
    const bytes = new TextEncoder().encode(body);
    return { ok: true, status: 200, arrayBuffer: async () => bytes.buffer, json: async () => JSON.parse(body) };
  };
  return { fetch, urls };
}

// A fake ORT bundle; like ORT's glue it binds console.error when it loads, after the loader's tap.
function importer(sc, { version = '1.31.1', placements = [] } = {}) {
  const imported = [];
  const importModule = async (url) => {
    imported.push(url);
    const glue = sc.console.error.bind(sc.console);
    const created = [];
    return { created, env: { wasm: {}, versions: { web: version } }, InferenceSession: { async create(model, options) {
      created.push({ model, options });
      for (const line of placements.shift() || []) glue(line);
      return { model };
    } } };
  };
  return { importModule, imported };
}

const checks = {
  async choose() {
    const caps = (o) => ({ secure_context: true, webgpu: true, adapter: ADAPTER.info, adapter_error: null, jspi: true, ...o });
    const pick = (o, opts) => { const c = L.chooseBuild(caps(o), opts); return `${c.build}/${c.provider}/${c.reason}`; };
    assert.equal(pick({}), 'jspi/webgpu/jspi-webgpu');
    assert.equal(pick({ jspi: false }), 'asyncify/webgpu/no-jspi');
    assert.equal(pick({ secure_context: false }), 'cpu/wasm/no-secure-context');
    assert.equal(pick({ webgpu: false, adapter: null }), 'cpu/wasm/no-webgpu');
    assert.equal(pick({ adapter: null }), 'cpu/wasm/no-adapter');
    assert.equal(pick({ adapter: null, adapter_error: 'device lost' }), 'cpu/wasm/adapter-error');
    assert.equal(pick({ adapter: null, adapter_error: 'timeout' }), 'cpu/wasm/adapter-timeout');
    assert.equal(pick({ secure_context: false }, { build: 'asyncify' }), 'asyncify/webgpu/requested');
    assert.throws(() => L.chooseBuild(caps({}), { build: 'jsep' }), (e) => e.name === 'OrtWebLoadError' && e.code === 'unknown-build');
    for (const code of ['jspi-webgpu', 'no-jspi', 'no-secure-context', 'no-webgpu', 'no-adapter', 'adapter-error', 'adapter-timeout', 'requested']) {
      assert.equal(typeof L.REASONS[code], 'string', code);
    }
    assert.deepEqual(L.BUILD_ORDER, ['jspi', 'asyncify', 'cpu']);
  },
  async probe() {
    const sc = scope();
    const caps = await L.probeCapabilities({ scope: sc });
    assert.deepEqual(caps, { secure_context: true, cross_origin_isolated: true, jspi: true, webgpu: true, hardware_concurrency: 8,
      adapter: { vendor: 'google', architecture: 'swiftshader', device: '', description: 'SwiftShader', is_fallback: false }, adapter_error: null });
    const insecure = scope({ secure: false });
    assert.equal((await L.probeCapabilities({ scope: insecure })).adapter, null);
    assert.deepEqual(insecure.calls, [], 'an insecure page asks for no adapter');
    assert.equal((await L.probeCapabilities({ scope: scope({ jspi: 'half' }) })).jspi, false, 'JSPI needs Suspending and promising');
    assert.equal((await L.probeCapabilities({ scope: scope({ gpu: 'none' }) })).webgpu, false);
    assert.equal((await L.probeCapabilities({ scope: scope({ gpu: 'null' }) })).adapter, null);
    assert.equal((await L.probeCapabilities({ scope: scope({ gpu: 'throws' }) })).adapter_error, 'device lost');
    assert.equal((await L.probeCapabilities({ scope: scope({ gpu: 'hangs' }) })).adapter_error, 'timeout');
  },
  async threads() {
    const caps = (o) => ({ cross_origin_isolated: true, hardware_concurrency: 8, ...o });
    assert.deepEqual(L.threadCount(caps({})), { threads: 4, threads_note: null });
    assert.deepEqual(L.threadCount(caps({ hardware_concurrency: 3 })), { threads: 2, threads_note: null });
    assert.deepEqual(L.threadCount(caps({}), 3), { threads: 3, threads_note: null });
    assert.deepEqual(L.threadCount(caps({ cross_origin_isolated: false }), 3), { threads: 1, threads_note: 'not-isolated' });
  },
  async manifest() {
    const { manifest } = site();
    const entry = L.buildEntry(manifest, 'jspi');
    assert.deepEqual([entry.bundle.file, entry.loader.file, entry.wasm.file, entry.path],
      ['ort.jspi.min.mjs', 'ort-wasm-simd-threaded.jspi.mjs', 'ort-wasm-simd-threaded.jspi.wasm', 'ort/1.31.1-0000000000000000/']);
    assert.equal(L.buildEntry(site({ bundles: ['bundle.min.mjs'] }).manifest, 'cpu').bundle.file, 'ort.wasm.bundle.min.mjs');
    assert.equal(L.buildEntry(site({ bundles: ['mjs', 'bundle.min.mjs'] }).manifest, 'asyncify').bundle.file, 'ort.webgpu.mjs');
    const refuses = (m, build, code) => assert.throws(() => L.buildEntry(m, build), (e) => e.code === code, code);
    refuses(site({ bundles: [] }).manifest, 'cpu', 'no-bundle');
    refuses(site({ builds: ['cpu'] }).manifest, 'jspi', 'build-not-staged');
    refuses({ ...manifest, schema_version: 2 }, 'cpu', 'bad-manifest');
    const edit = (f) => { const m = structuredClone(manifest); f(m.builds[2]); return m; };
    refuses(edit((b) => { b.path = 'ort/../../etc/'; }), 'cpu', 'bad-manifest');
    refuses(edit((b) => { b.files[0].file = '../x.wasm'; }), 'cpu', 'bad-manifest');
    refuses(edit((b) => { b.files[0].sha256 = 'abc'; }), 'cpu', 'bad-manifest');
    refuses(edit((b) => { b.files.push({ ...b.files[0], file: 'other.wasm' }); }), 'cpu', 'bad-manifest');
  },
  async plan() {
    const { files } = site();
    const sc = scope({ jspi: false });
    const { fetch, urls } = fetcher(files);
    const { provenance } = await L.planOrtWeb({ scope: sc, fetch });
    assert.deepEqual(urls, ['https://example.test/app/ort/manifest.json'], 'a plan fetches nothing of the build');
    assert.deepEqual([provenance.build, provenance.reason, provenance.verified, provenance.ort_web, provenance.build_hash],
      ['asyncify', 'no-jspi', false, null, '1111111111111111']);
    const given = await L.planOrtWeb({ scope: sc, fetch, manifest: site().manifest, build: 'cpu' });
    assert.deepEqual([given.provenance.build, given.provenance.reason, urls.length], ['cpu', 'requested', 1], 'a given manifest is not fetched');
  },
  async load() {
    const { files } = site();
    for (const [build, o] of [['jspi', {}], ['asyncify', { jspi: false }], ['cpu', { gpu: 'none' }]]) {
      const sc = scope(o);
      const { fetch, urls } = fetcher(files);
      const { importModule, imported } = importer(sc);
      const { ort, provenance, executionProviders } = await L.loadOrtWeb({ scope: sc, fetch, importModule });
      const dir = `https://example.test/app/${provenance.path}`;
      const [stem, prefix] = STEMS[build];
      assert.equal(provenance.build, build);
      assert.deepEqual(urls.slice(1).sort(), [`${dir}${prefix}.min.mjs`, `${dir}${stem}.mjs`, `${dir}${stem}.wasm`].sort(), 'only the chosen build is fetched');
      assert.equal(urls[0], 'https://example.test/app/ort/manifest.json');
      assert.deepEqual(imported, [`${dir}${prefix}.min.mjs`], 'its own bundle is imported');
      assert.deepEqual(ort.env.wasm.wasmPaths, { mjs: `${dir}${stem}.mjs`, wasm: `${dir}${stem}.wasm` }, 'its own loader and wasm');
      assert.equal(new TextDecoder().decode(ort.env.wasm.wasmBinary), `${build}:${stem}.wasm`, 'the checked wasm bytes go to ORT');
      assert.deepEqual([ort.env.wasm.numThreads, ort.env.wasm.proxy], [4, false]);
      assert.deepEqual(executionProviders, [build === 'cpu' ? 'wasm' : 'webgpu']);
      assert.deepEqual([provenance.ort_version, provenance.ort_web, provenance.verified, provenance.manifest.image_receipt_sha256],
        ['1.31.1', '1.31.1', true, 'b'.repeat(64)]);
      assert.equal(provenance.files.wasm.sha256, sha(`${build}:${stem}.wasm`));
      assert.equal(provenance.reason, { jspi: 'jspi-webgpu', asyncify: 'no-jspi', cpu: 'no-webgpu' }[build]);
      assert.deepEqual(JSON.parse(JSON.stringify(provenance)), provenance, 'the provenance is plain JSON');
    }
    const sc = scope({ isolated: false });
    const { fetch } = fetcher(files);
    const { provenance } = await L.loadOrtWeb({ scope: sc, fetch, importModule: importer(sc).importModule, base: '/app/' });
    assert.deepEqual([provenance.threads, provenance.threads_note], [1, 'not-isolated']);
  },
  async refusals() {
    const { files } = site();
    const refuses = async (o, serve, code, { version, verify } = {}) => {
      const sc = scope(o);
      const { importModule, imported } = importer(sc, { version });
      await assert.rejects(L.loadOrtWeb({ scope: sc, fetch: fetcher(files, serve).fetch, importModule, verify }), (e) => {
        assert.equal(e.code, code);
        if (code !== 'fetch-failed' || !serve['ort/manifest.json']) assert.equal(e.provenance.build, 'jspi', 'the refusal carries the choice');
        return true;
      });
      if (code !== 'version-mismatch') assert.deepEqual(imported, [], 'nothing is imported after a refusal');
    };
    const wasm = 'ort/1.31.1-0000000000000000/ort-wasm-simd-threaded.jspi.wasm';
    const bundle = 'ort/1.31.1-0000000000000000/ort.jspi.min.mjs';
    await refuses({}, { [wasm]: '<!doctype html>' }, 'hash-mismatch');
    await refuses({}, { [bundle]: 'export const env = {};' }, 'hash-mismatch');
    await refuses({}, { [wasm]: 404 }, 'fetch-failed');
    await refuses({}, { 'ort/manifest.json': 404 }, 'fetch-failed');
    await refuses({ subtle: false }, {}, 'unverifiable');
    await refuses({}, {}, 'version-mismatch', { version: '1.30.0' });
    const sc = scope({ subtle: false });
    const loaded = await L.loadOrtWeb({ scope: sc, fetch: fetcher(files, { [wasm]: 'other' }).fetch, importModule: importer(sc).importModule, verify: false });
    assert.equal(loaded.provenance.verified, false, 'verify: false loads unchecked and says so');
  },
  async session() {
    const { files } = site();
    const sc = scope();
    const lines = [['Node(s) placed on [WebGpuExecutionProvider]. Number of nodes: 727', 'Node(s) placed on [CPUExecutionProvider]. Number of nodes: 10'],
      [' All nodes placed on [WebGpuExecutionProvider]. Number of nodes: 5'], []];
    const loaded = await L.loadOrtWeb({ scope: sc, fetch: fetcher(files).fetch, importModule: importer(sc, { placements: lines }).importModule });
    const model = new Uint8Array([1, 2]);
    await L.createSession(loaded, model, { scope: sc, options: { graphOptimizationLevel: 'all' } });
    assert.deepEqual(loaded.ort.created[0].options, { graphOptimizationLevel: 'all', executionProviders: ['webgpu'], logSeverityLevel: 0, logVerbosityLevel: 0 });
    assert.deepEqual(loaded.provenance.session, { placements: { WebGpuExecutionProvider: 727, CPUExecutionProvider: 10 }, nodes: 737,
      on_provider: 727, share: 727 / 737, proven: true });
    await L.createSession(loaded, model, { scope: sc });
    assert.deepEqual(loaded.provenance.session.placements, { WebGpuExecutionProvider: 5 }, 'a second session counts its own lines only');
    await L.createSession(loaded, model, { scope: sc });
    assert.equal(loaded.provenance.session.proven, false, 'no placement line proves nothing');
    assert.equal(sc.lines.length, 3, 'the tapped lines still reach the console');
    assert.deepEqual(L.countPlacements(['x', 'All nodes placed on [CPUExecutionProvider]. Number of nodes: 717']), { CPUExecutionProvider: 717 });
  },
  async args() {
    const opts = check.parseArgs([...base, '--fake-ort']);
    assert.deepEqual([opts.in, opts.fakeOrt, opts.runs, opts.dims], ['page', true, 1, [1, 3, 640, 640]]);
    assert.equal(check.parseArgs([...base, '--worker', 'w.mjs']).worker, 'w.mjs');
    assert.throws(() => check.parseArgs([...base.slice(0, 2), '--case', 'webnn', ...base.slice(4)]), /--case is one of/);
    assert.throws(() => check.parseArgs([...base, '--in', 'iframe']), /--in is page or worker/);
    assert.throws(() => check.parseArgs([...base, '--worker', 'w.mjs', '--model', 'm.onnx']), /no --model or --in with it/);
    assert.throws(() => check.parseArgs([...base, '--input-dims', '1,0,3']), /--input-dims takes positive integers/);
    const detect = check.parseArgs([...base, '--worker', 'w.mjs', '--build', 'cpu', '--image', 'i.jpg', '--threshold', '0.3']);
    assert.deepEqual([detect.build, detect.image, detect.threshold], ['cpu', 'i.jpg', 0.3]);
    assert.equal(check.parseArgs([...base, '--worker', 'w.mjs']).threshold, 0.25, 'the comparator keeps detections at 0.25 or more');
    assert.throws(() => check.parseArgs([...base, '--image', 'i.jpg']), /give --worker/);
    assert.throws(() => check.parseArgs([...base, '--build', 'cpu']), /give --worker/);
    assert.throws(() => check.parseArgs([...base, '--worker', 'w.mjs', '--threshold', '2']), /--threshold is between 0 and 1/);
    assert.deepEqual(Object.keys(check.CASES), ['jspi', 'asyncify', 'no-adapter', 'no-webgpu', 'insecure', 'not-isolated']);
  },
  async fake() {
    const files = check.fakeOrt();
    const manifest = JSON.parse(files['manifest.json']);
    for (const build of L.BUILD_ORDER) {
      const entry = L.buildEntry(manifest, build);
      for (const item of [entry.bundle, entry.loader, entry.wasm]) {
        const body = files[entry.path.slice('ort/'.length) + item.file];
        assert.equal(createHash('sha256').update(body).digest('hex'), item.sha256, `${build} ${item.file}`);
      }
    }
    assert.match(files[`1.31.1-${'1'.repeat(16)}/ort.jspi.min.mjs`], /placed on \[WebGpuExecutionProvider\]/);
    assert.match(files[`1.31.1-${'3'.repeat(16)}/ort.wasm.min.mjs`], /placed on \[CPUExecutionProvider\]/);
  },
  async serve() {
    mkdirSync(`${dir}/site/inference`, { recursive: true });
    writeFileSync(`${dir}/site/inference/w.mjs`, '// worker');
    writeFileSync(`${dir}/secret`, 'secret');
    const direct = check.parseArgs(['--site', `${dir}/site`, '--case', 'jspi', '--out', 'x']);
    // fetch() folds %2e%2e before it sends, so only a direct call reaches the guard with a real ..
    for (const p of ['/site/../secret', '/site/inference/../../secret']) assert.equal(check.route(direct, p), null, p);
    assert.equal(check.route(direct, '/site/inference/w.mjs').file, `${dir}/site/inference/w.mjs`);
    assert.equal(check.route(direct, '/ort-web-loader.mjs').file, direct.loader);
    assert.match(check.route(direct, '/').body, /ORT Web loader check/);
    for (const p of ['/model.onnx', '/image', '/elsewhere']) assert.equal(check.route(direct, p), null, p);
    for (const [name, isolated] of [['jspi', true], ['not-isolated', false]]) {
      const opts = { ...check.parseArgs(['--site', `${dir}/site`, '--case', name, '--out', 'x', '--fake-ort']), fake: check.fakeOrt() };
      assert.equal(check.route(opts, '/site/ort/manifest.json').type, 'application/json', `${name} the fake manifest`);
      await assertServes(await check.serve(opts), [['/worker.mjs', 200], ['/site/ort/none.wasm', 404]],
      { 'cross-origin-embedder-policy': isolated ? 'require-corp' : null, 'cross-origin-opener-policy': isolated ? 'same-origin' : null },
      `${name} `);
    }
  },
};
await checks[scenario]();
process.stdout.write(`ok ${scenario}\n`);
EOF

for scenario in choose probe threads manifest plan load refusals session args fake serve; do
  t_case "the loader and its Chrome check in node: ${scenario}"
  out="$(node "${w}/loader.test.mjs" "${LOADER}" "${CHECK}" "$(t_mktemp -d)" "${scenario}" 2>&1)"
  t_assert_eq 0 "$?" "${out}"
  t_assert_contains "${out}" "ok ${scenario}"
done

t_summary
