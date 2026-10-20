#!/usr/bin/env node
// webgpu-canvas-readback.js <URL | page.html> [--min-colours N] [--wait-ms N] [--screenshot FILE]: read a WebGPU canvas's frame back in headless Chrome, whose screenshot of it is white. See docs/docs-sites.md#proving-a-webgpu-page
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { findChrome, launch, serve, sleep } = require('./check-docs-sidebars.js');

// No GPU in the image: SwiftShader's Vulkan backs the WebGPU adapter.
const WEBGPU_FLAGS = ['--enable-unsafe-webgpu', '--enable-features=Vulkan', '--use-angle=swiftshader', '--use-webgpu-adapter=swiftshader'];
const FRAME_TIMEOUT_MS = 10000;

function fail(message, code = 2) {
  process.stderr.write(`webgpu-canvas-readback: ${message}\n`);
  process.exit(code);
}

// Runs in the page before its own scripts: the canvas stays copyable, and the next frame is copied out after its last submit.
function install() {
  if (typeof GPUCanvasContext === 'undefined') {
    window.__webgpuReadback = async () => ({ error: 'this browser has no WebGPU' });
    return;
  }
  const st = { submits: 0, want: null };
  const configure = GPUCanvasContext.prototype.configure;
  GPUCanvasContext.prototype.configure = function (cfg) {
    Object.assign(st, { device: cfg.device, format: cfg.format, canvas: this.canvas });
    return configure.call(this, { ...cfg, usage: (cfg.usage ?? GPUTextureUsage.RENDER_ATTACHMENT) | GPUTextureUsage.COPY_SRC });
  };
  const current = GPUCanvasContext.prototype.getCurrentTexture;
  GPUCanvasContext.prototype.getCurrentTexture = function () {
    st.texture = current.call(this);
    return st.texture;
  };
  const submit = GPUQueue.prototype.submit;
  const copy = async ({ texture, device, format, canvas }) => {
    if (!/^(rgba|bgra)8unorm/.test(format)) return { error: `canvas format ${format}: only 8-bit formats are read back` };
    const w = texture.width;
    const h = texture.height;
    const bytesPerRow = Math.ceil((w * 4) / 256) * 256;
    const buffer = device.createBuffer({ size: bytesPerRow * h, usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ });
    const encoder = device.createCommandEncoder();
    encoder.copyTextureToBuffer({ texture }, { buffer, bytesPerRow }, [w, h]);
    submit.call(device.queue, [encoder.finish()]);
    await buffer.mapAsync(GPUMapMode.READ);
    const src = new Uint8Array(buffer.getMappedRange());
    const bgra = format.startsWith('bgra');
    const image = new ImageData(w, h);
    const seen = new Map();
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const s = y * bytesPerRow + x * 4;
        const d = (y * w + x) * 4;
        const rgb = [src[s + (bgra ? 2 : 0)], src[s + 1], src[s + (bgra ? 0 : 2)]];
        image.data.set([...rgb, 255], d);
        const key = (rgb[0] << 16) | (rgb[1] << 8) | rgb[2];
        seen.set(key, (seen.get(key) || 0) + 1);
      }
    }
    buffer.unmap();
    // A 2D canvas over the WebGPU one, so a screenshot taken now shows the frame.
    const overlay = document.createElement('canvas');
    Object.assign(overlay, { width: w, height: h });
    overlay.getContext('2d').putImageData(image, 0, 0);
    const r = canvas.getBoundingClientRect();
    overlay.style.cssText = `position:fixed;left:${r.left}px;top:${r.top}px;width:${r.width}px;height:${r.height}px;z-index:2147483647`;
    document.body.appendChild(overlay);
    const top = [...seen].sort((a, b) => b[1] - a[1]).slice(0, 5).map(([k, n]) => `#${k.toString(16).padStart(6, '0')} ${n}`);
    return { width: w, height: h, format, colours: seen.size, top, submits: st.submits };
  };
  GPUQueue.prototype.submit = function (buffers) {
    const result = submit.call(this, buffers);
    st.submits++;
    if (st.want && st.texture) {
      const resolve = st.want;
      st.want = null;
      // A microtask runs after the frame's last submit and before its texture is presented.
      queueMicrotask(() => copy(st).then(resolve, (e) => resolve({ error: String(e) })));
    }
    return result;
  };
  window.__webgpuReadback = () => new Promise((resolve) => { st.want = resolve; });
}

// The verdict on one read-back: null when it passes, else why not.
function verdict(frame, minColours) {
  if (frame.error) return frame.error;
  if (frame.colours < minColours) return `${frame.colours} colour(s), fewer than ${minColours}: the canvas shows no scene`;
  return null;
}

function parseArgs(argv) {
  const opts = { minColours: 2, waitMs: 3000, screenshot: '' };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const flag = { '--min-colours': 'minColours', '--wait-ms': 'waitMs', '--screenshot': 'screenshot' }[argv[i]];
    if (!flag) { rest.push(argv[i]); continue; }
    if (i + 1 >= argv.length) fail(`${argv[i]} needs a value`);
    opts[flag] = flag === 'screenshot' ? argv[++i] : Number(argv[++i]);
    if (flag !== 'screenshot' && !(opts[flag] >= 0)) fail(`${argv[i - 1]} takes a number, got '${argv[i]}'`);
  }
  if (rest.length !== 1) fail('usage: webgpu-canvas-readback.js <URL | page.html> [--min-colours N] [--wait-ms N] [--screenshot FILE]');
  return { target: rest[0], ...opts };
}

async function main() {
  const { target, minColours, waitMs, screenshot } = parseArgs(process.argv.slice(2));
  const isUrl = /^https?:\/\//.test(target);
  if (!isUrl && !(target.endsWith('.html') && fs.existsSync(target))) fail(`${target} is neither a URL nor an .html file`);
  const chrome = findChrome();
  if (!chrome) fail('no Chrome (CHROME_EXECUTABLE, chrome, chromium): the family image carries Chrome for Testing');
  const server = isUrl ? null : await serve(path.resolve(path.dirname(target)));
  const url = server ? `http://127.0.0.1:${server.address().port}/${encodeURIComponent(path.basename(target))}` : target;
  const browser = await launch(chrome, WEBGPU_FLAGS);
  let frame;
  try {
    await browser.send('Page.addScriptToEvaluateOnNewDocument', { source: `(${install})()` });
    await browser.send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false });
    await browser.send('Page.navigate', { url });
    for (let i = 0; i < 300 && !browser.loaded.length; i++) await sleep(100);
    await sleep(waitMs);
    const timeout = `new Promise((r) => setTimeout(() => r({ error: 'no WebGPU frame in ${FRAME_TIMEOUT_MS / 1000} s' }), ${FRAME_TIMEOUT_MS}))`;
    const answer = await browser.send('Runtime.evaluate', { expression: `Promise.race([window.__webgpuReadback(), ${timeout}])`, awaitPromise: true, returnByValue: true });
    frame = answer.result.result.value || { error: 'the read-back returned nothing' };
    if (screenshot) fs.writeFileSync(screenshot, Buffer.from((await browser.send('Page.captureScreenshot', { format: 'png' })).result.data, 'base64'));
  } finally {
    browser.close();
    if (server) server.close();
  }
  const why = verdict(frame, minColours);
  const shape = frame.error ? '' : ` ${frame.width}x${frame.height} ${frame.format}, ${frame.colours} colours (${frame.top.join(', ')})`;
  process.stdout.write(`webgpu-canvas-readback: ${url},${shape} ${browser.product}\n`);
  if (why) fail(why, 1);
}

if (require.main === module) main().catch((e) => fail(e.stack || String(e)));
else module.exports = { install, verdict };
