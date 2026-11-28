#!/usr/bin/env bash
# The ORT Web parity report over fixture builds, and its page and server against a fake ORT module without Chrome. See docs/docs-sites.md#detector-parity-of-the-ort-web-builds
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_skip_unless "a POSIX python3" t_posix_python
t_private_tmpdir
w="$(t_mktemp -d)"
REPORT_TESTS="${TESTS_DIR}/../../../shared/python/tests/test_ort_web_parity.py"

t_case "the report: verdicts, tolerance edges, the cat rule, refusals and its shape"
out="$("${PREFLIGHT_PYTHON:-python3}" -I "${REPORT_TESTS}" 2>&1)"
t_assert_eq 0 "$?" "${out}"
t_assert_contains "${out}" "OK"

t_skip_unless "node with a global fetch (18 and later)" node -e 'process.exit(typeof fetch === "function" ? 0 : 1)'

cat > "${w}/fake.js" <<'EOF'
const FAKE = `export const env = { wasm: {}, versions: { web: '9.9.9' } };
export class Tensor { constructor(type, data, dims) { Object.assign(this, { type, data, dims }); } }
export const InferenceSession = { async create(model, options) {
  globalThis.created = { bytes: model.length, options, wasm: { ...env.wasm }, logLevel: env.logLevel };
  if (globalThis.fail) throw new Error('no available backend found');
  return { inputNames: ['images'], outputNames: [globalThis.output || 'output0'],
    async run(feeds) { (globalThis.feeds = globalThis.feeds || []).push(feeds); const d = new Float32Array([1.5, -2, 3]);
      return { [globalThis.output || 'output0']: { dims: [1, 300, 6], type: 'float32', getData: async () => d } }; },
    async release() { globalThis.released = true; } }; } };`;
const harness = require(process.argv[2]);
const { parseArgs, route, serve, runInPage, consoleLine } = harness;
const assert = require('node:assert/strict');
const { mkdirSync, writeFileSync } = require('node:fs');
const { join } = require('node:path');
const [dir, scenario] = process.argv.slice(3);
const site = join(dir, 'site');
mkdirSync(join(site, 'ort', 'b'), { recursive: true });
for (const [file, body] of [[join(site, 'ort', 'b', 'x.wasm'), 'wasm'], [join(dir, 'secret'), 'secret'], [join(dir, 'model.onnx'), 'model'],
  [join(dir, 'input.bin'), Buffer.from(new Float32Array([0.5, 0.25]).buffer)]]) writeFileSync(file, body);
const opts = { site, model: join(dir, 'model.onnx'), input: join(dir, 'input.bin'), jsDir: '' };
// Spelled out, not read from the module: a header dropped there must fail here.
const ISOLATED = { 'cross-origin-opener-policy': 'same-origin', 'cross-origin-embedder-policy': 'require-corp',
  'cross-origin-resource-policy': 'same-origin', 'cache-control': 'no-store' };
const fakeModule = `data:text/javascript,${encodeURIComponent(FAKE)}`;
async function check() {
  if (scenario === 'args') {
    const full = ['--site', 's', '--module', 'm', '--wasm-dir', 'w', '--ep', 'webgpu', '--gpu', 'none', '--model', 'x', '--input', 'i', '--out', 'o'];
    assert.deepEqual([parseArgs(full).runs, parseArgs(full).threads, parseArgs([...full, '--runs', '3']).runs], [2, 2, 3]);
    assert.throws(() => parseArgs(full.slice(0, -2)), /--out is required/);
    assert.throws(() => parseArgs([...full.slice(0, 6), '--ep', 'webnn', ...full.slice(8)]), /--ep is webgpu or wasm/);
    assert.throws(() => parseArgs([...full.slice(0, 8), '--gpu', 'swiftshader', ...full.slice(10)]), /--gpu is webgpu or none/);
    assert.throws(() => parseArgs([...full, '--runs', '0']), /--runs takes a positive integer/);
    assert.throws(() => parseArgs([...full, '--wat', '1']), /unknown option --wat/);
    assert.equal(consoleLine({ args: [{ value: 'a' }, { value: 3 }, { description: 'Error: b' }] }), 'a 3 Error: b');
  } else if (scenario === 'routes') {
    assert.equal(route(opts, '/site/ort/b/x.wasm').file, join(site, 'ort', 'b', 'x.wasm'));
    assert.equal(route(opts, '/site/../secret'), null, 'nothing outside the site is served');
    assert.equal(route(opts, '/site/'), null, 'the site root itself is no file');
    assert.equal(route(opts, '/js/ort.min.mjs'), null, 'no JS layer is served without --js-dir');
    assert.equal(route(opts, '/model.onnx').file, opts.model);
    assert.equal(route(opts, '/elsewhere'), null);
    const server = await serve(opts);
    const base = `http://127.0.0.1:${server.address().port}`;
    try {
      for (const [url, status, type] of [['/', 200, 'text/html'], ['/site/ort/b/x.wasm', 200, 'application/wasm'],
        ['/site/%2e%2e/secret', 404, undefined], ['/nothing', 404, undefined]]) {
        const response = await fetch(base + url);
        assert.equal(response.status, status, url);
        if (type) assert.equal(response.headers.get('content-type'), type, url);
        for (const [header, value] of Object.entries(ISOLATED)) assert.equal(response.headers.get(header), value, `${url} ${header}`);
      }
    } finally { server.close(); }
  } else {
    const server = await serve(opts);
    const base = `http://127.0.0.1:${server.address().port}/`;
    try {
      globalThis.fail = scenario === 'create-fails';
      globalThis.output = scenario === 'no-output0' ? 'boxes' : undefined;
      const got = await runInPage({ base, module: fakeModule, wasmDir: 'site/ort/b/', ep: 'webgpu', threads: 2, runs: 2 });
      assert.equal(globalThis.created.bytes, 5, 'the served model reaches the session');
      assert.deepEqual(globalThis.created.wasm, { wasmPaths: `${base}site/ort/b/`, numThreads: 2, proxy: false }, 'the build directory is wasmPaths');
      assert.equal(globalThis.created.logLevel, 'verbose');
      assert.deepEqual(globalThis.created.options, { executionProviders: ['webgpu'], logSeverityLevel: 0, logVerbosityLevel: 0 });
      if (scenario === 'create-fails') {
        assert.match(got.error, /no available backend found/);
        assert.deepEqual(got.runs, []);
      } else if (scenario === 'no-output0') {
        assert.match(got.error, /the model has no output0: boxes/);
      } else {
        assert.equal(got.error, null);
        assert.equal(got.ortVersion, '9.9.9');
        assert.equal(got.runs.length, 2, 'the same input runs as often as asked');
        assert.deepEqual(Array.from(globalThis.feeds[0].images.data), [0.5, 0.25], 'the served tensor is the input');
        assert.deepEqual(globalThis.feeds[0].images.dims, [1, 3, 640, 640]);
        assert.deepEqual(Array.from(new Float32Array(Uint8Array.from(Buffer.from(got.runs[1].data, 'base64')).buffer)), [1.5, -2, 3]);
        assert.deepEqual([got.runs[0].dims, got.runs[0].type], [[1, 300, 6], 'float32']);
        assert.equal(globalThis.released, true);
        assert.equal(got.crossOriginIsolated, false);
      }
    } finally { server.close(); }
  }
}
check().then(() => process.stdout.write(`ok ${scenario}\n`), (error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
EOF

for scenario in args routes runs create-fails no-output0; do
  t_case "the harness without Chrome: ${scenario}"
  out="$(node "${w}/fake.js" "${TESTS_DIR}/../ort-web-detector-parity.js" "${w}" "${scenario}" 2>&1)"
  t_assert_eq 0 "$?" "${out}"
  t_assert_contains "${out}" "ok ${scenario}"
done

t_summary
