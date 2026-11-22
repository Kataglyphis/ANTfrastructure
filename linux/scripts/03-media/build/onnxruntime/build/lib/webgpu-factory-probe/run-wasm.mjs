// Factory registration is independent of adapter availability and inference.
import {readFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';

try {
  const [loader, wasm, flavor] = process.argv.slice(2);
  if (process.argv.length !== 5 || !['asyncify', 'jspi'].includes(flavor)) {
    throw new Error('Expected the original loader, WASM file and flavor');
  }
  const jspiSupported = typeof WebAssembly.Suspending === 'function';
  if (flavor === 'jspi' && !jspiSupported) {
    throw new Error('This Node runtime does not support JSPI');
  }
  process.stdout.write('WEBGPU-WASM-NODE: ' + JSON.stringify({version: process.version, jspiSupported}) + '\n');
  const {default: initialize} = await import(pathToFileURL(loader).href);
  const module = await initialize({
    wasmBinary: new Uint8Array(await readFile(wasm)),
    numThreads: 1,
    print: value => process.stdout.write(String(value) + '\n'),
    printErr: value => process.stderr.write(String(value) + '\n'),
  });
  if (typeof module._OrtWebGpuFactoryProbe !== 'function') {
    throw new Error('The compiled WASM module has no factory probe export');
  }
  const status = await module._OrtWebGpuFactoryProbe(1);
  if (status !== 0) {
    throw new Error('The compiled factory probe returned ' + String(status));
  }
} catch (error) {
  process.stderr.write('WEBGPU-WASM-RUNTIME FAIL: ' + String(error) + '\n');
  process.exitCode = 1;
}
