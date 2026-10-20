#!/usr/bin/env bash
# webgpu-canvas-readback.js: its in-page read-back against fakes of the WebGPU API, and the CLI in headless Chrome. See docs/docs-sites.md#proving-a-webgpu-page
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
TOOL="${SCRIPTS}/webgpu-canvas-readback.js"
_tmp="$(mktemp -d)"
trap 'rm -rf "${_tmp}"' EXIT

t_skip_unless "node with a global WebSocket (22 and later)" node -e 'process.exit(typeof WebSocket === "function" ? 0 : 1)'

# A 3x2 frame with rows padded to 256 bytes, as copyTextureToBuffer lays it out: red red green / blue blue blue.
cat > "${_tmp}/fakes.js" <<'EOF'
const assert = require('node:assert');
const { install, verdict } = require(process.argv[2]);
const scenario = process.argv[3];
const W = 3, H = 2, ROW = 256;
const bytes = new Uint8Array(ROW * H);
const pixel = (x, y, [r, g, b], bgra) => bytes.set(bgra ? [b, g, r, 255] : [r, g, b, 255], y * ROW + x * 4);
const painted = [];
Object.assign(global, {
  window: global,
  GPUTextureUsage: { COPY_SRC: 1, RENDER_ATTACHMENT: 16 },
  GPUBufferUsage: { MAP_READ: 1, COPY_DST: 8 },
  GPUMapMode: { READ: 1 },
  ImageData: class { constructor(w, h) { this.data = new Uint8ClampedArray(w * h * 4); } },
  document: { body: { appendChild() {} }, createElement: () => ({ style: {}, getContext: () => ({ putImageData: (image) => painted.push(image) }) }) },
});
let configured, buffer;
global.GPUCanvasContext = class { configure(cfg) { configured = cfg; } getCurrentTexture() { return { width: W, height: H }; } };
global.GPUQueue = class { submit() {} };
const queue = new GPUQueue();
const device = {
  queue,
  createBuffer: (desc) => { buffer = desc; return { mapAsync: async () => {}, getMappedRange: () => bytes.buffer, unmap() {} }; },
  createCommandEncoder: () => ({ copyTextureToBuffer: (src, dst) => { buffer.bytesPerRow = dst.bytesPerRow; }, finish: () => 'copy' }),
};
const frame = async (format) => {
  for (const [x, y, rgb] of [[0, 0, [255, 0, 0]], [1, 0, [255, 0, 0]], [2, 0, [0, 255, 0]], [0, 1, [0, 0, 255]], [1, 1, [0, 0, 255]], [2, 1, [0, 0, 255]]]) pixel(x, y, rgb, format.startsWith('bgra'));
  install();
  const ctx = new GPUCanvasContext();
  ctx.canvas = { getBoundingClientRect: () => ({ left: 0, top: 0, width: W, height: H }) };
  ctx.configure({ device, format });
  const pending = window.__webgpuReadback();
  ctx.getCurrentTexture();
  queue.submit(['frame']);
  return Promise.race([pending, new Promise((r) => setTimeout(() => r('no read-back after the submit'), 2000))]);
};
(async () => {
  if (scenario === 'bgra' || scenario === 'rgba') {
    const got = await frame(`${scenario}8unorm`);
    assert.equal(configured.usage, 16 | 1, 'COPY_SRC joins the default RENDER_ATTACHMENT usage');
    assert.equal(buffer.size, ROW * H, 'rows are padded to 256 bytes');
    assert.equal(buffer.bytesPerRow, ROW);
    assert.deepEqual(got.top, ['#0000ff 3', '#ff0000 2', '#00ff00 1']);
    assert.equal(got.colours, 3);
    assert.deepEqual([...painted[0].data.slice(0, 4)], [255, 0, 0, 255], 'the overlay is painted in RGBA');
  } else if (scenario === 'half-float') {
    assert.match((await frame('rgba16float')).error, /canvas format rgba16float: only 8-bit formats/);
  } else if (scenario === 'no-webgpu') {
    delete global.GPUCanvasContext;
    install();
    assert.equal((await window.__webgpuReadback()).error, 'this browser has no WebGPU');
  } else if (scenario === 'verdict') {
    assert.equal(verdict({ colours: 3 }, 2), null);
    assert.match(verdict({ colours: 1 }, 2), /^1 colour\(s\), fewer than 2: the canvas shows no scene$/);
    assert.equal(verdict({ error: 'no WebGPU frame in 10 s' }, 2), 'no WebGPU frame in 10 s');
  }
  console.log(`ok ${scenario}`);
})().catch((e) => { console.log(`FAIL ${scenario}: ${e.message}`); process.exit(1); });
EOF

t_case "a BGRA frame is copied out after its submit, rows unpadded and channels swapped to RGB"
t_assert_contains "$(t_out node "${_tmp}/fakes.js" "${TOOL}" bgra)" "ok bgra"

t_case "an RGBA frame keeps its channel order"
t_assert_contains "$(t_out node "${_tmp}/fakes.js" "${TOOL}" rgba)" "ok rgba"

t_case "a half-float canvas, and a browser without WebGPU, are reported, never misread"
t_assert_contains "$(t_out node "${_tmp}/fakes.js" "${TOOL}" half-float)" "ok half-float"
t_assert_contains "$(t_out node "${_tmp}/fakes.js" "${TOOL}" no-webgpu)" "ok no-webgpu"

t_case "the verdict: one colour is a cleared canvas, an error is its own reason"
t_assert_contains "$(t_out node "${_tmp}/fakes.js" "${TOOL}" verdict)" "ok verdict"

t_case "a page that never draws a WebGPU frame fails in Chrome; bad arguments are usage errors"
t_needs "Chrome (CHROME_EXECUTABLE, chrome, google-chrome or chromium)" node -e "process.exit(require('${SCRIPTS}/check-docs-sidebars.js').findChrome() ? 0 : 1)"
printf '<!DOCTYPE html><html><body><p>no canvas</p></body></html>\n' > "${_tmp}/plain.html"
t_assert_rc 1 node "${TOOL}" "${_tmp}/plain.html" --wait-ms 0
t_assert_contains "$(t_out node "${TOOL}" "${_tmp}/plain.html" --wait-ms 0)" "no WebGPU frame in 10 s"
t_assert_rc 2 node "${TOOL}"
t_assert_rc 2 node "${TOOL}" "${_tmp}/plain.html" --min-colours
t_assert_rc 2 node "${TOOL}" "${_tmp}/plain.html" --wait-ms soon
t_assert_rc 2 node "${TOOL}" "${_tmp}/no-such-page.html"

t_summary
