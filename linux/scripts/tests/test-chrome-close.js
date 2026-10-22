'use strict';

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { EventEmitter, once } = require('node:events');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const { closeChrome, closeBrowsers } = require('../check-docs-sidebars.js');

const directory = () => fs.mkdtempSync(path.join(os.tmpdir(), 'chrome-close-test-'));
const socket = () => ({ close() {} });

async function writer(profile) {
  const proc = spawn(process.execPath, ['-e', `
    const fs = require('node:fs');
    const path = require('node:path');
    const file = path.join(process.argv[1], 'writer');
    fs.writeFileSync(file, 'alive');
    process.send('ready');
    setInterval(() => fs.appendFileSync(file, '.'), 5);
    setTimeout(() => process.exit(0), 10000);
  `, profile], { stdio: ['ignore', 'ignore', 'ignore', 'ipc'] });
  await once(proc, 'message');
  return proc;
}

test('profile removal follows a real child exit and retains bounded filesystem retries', async () => {
  const profile = directory();
  const proc = await writer(profile);
  const remove = fs.rmSync;
  let exited = false, removed = false;
  proc.once('exit', () => { exited = true; });
  fs.rmSync = (target, options) => {
    if (target === profile) {
      if (!exited) throw Object.assign(new Error('profile writer is still alive'), { code: 'ENOTEMPTY' });
      assert.ok(options.maxRetries > 0 && options.maxRetries <= 20);
      assert.ok(options.retryDelay > 0 && options.retryDelay * options.maxRetries * (options.maxRetries + 1) / 2 <= 15000);
      removed = true;
    }
    return remove(target, options);
  };
  try {
    await closeChrome(socket(), proc, profile);
    assert.ok(exited && removed);
    assert.equal(fs.existsSync(profile), false);
  } finally {
    fs.rmSync = remove;
    proc.kill('SIGKILL');
    remove(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  }
});

test('an already exited child still cleans its profile', async () => {
  const profile = directory();
  const proc = spawn(process.execPath, ['-e', ''], { stdio: 'ignore' });
  await once(proc, 'exit');
  await closeChrome(socket(), proc, profile);
  assert.equal(fs.existsSync(profile), false);
});

test('the caller termination callback runs before the same child-reaping bound', async () => {
  const profile = directory();
  const proc = await writer(profile);
  let killed = false;
  try {
    await closeChrome(socket(), proc, profile, 5000, () => { killed = true; proc.kill('SIGKILL'); });
    assert.ok(killed);
    assert.notEqual(proc.signalCode, null);
    assert.equal(fs.existsSync(profile), false);
  } finally {
    proc.kill('SIGKILL');
    fs.rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  }
});

test('a child that never exits fails within the bound and retains its live profile', { timeout: 2000 }, async () => {
  const profile = directory();
  const proc = new EventEmitter();
  proc.exitCode = null;
  proc.signalCode = null;
  proc.kill = () => true;
  try {
    await assert.rejects(closeChrome(socket(), proc, profile, 20), /did not exit within 20 ms/);
    assert.ok(fs.existsSync(profile));
    assert.equal(proc.listenerCount('exit'), 0);
  } finally {
    fs.rmSync(profile, { recursive: true, force: true });
  }
});

for (const code of ['ENOTEMPTY', 'EACCES']) {
  test(`cleanup ${code} remains fatal after the child has exited`, async () => {
    const profile = directory();
    const proc = await writer(profile);
    const remove = fs.rmSync;
    const failure = Object.assign(new Error(`cleanup failed: ${code}`), { code });
    fs.rmSync = (target, options) => {
      if (target === profile) throw failure;
      return remove(target, options);
    };
    try {
      await assert.rejects(closeChrome(socket(), proc, profile), (error) => error === failure);
      assert.notEqual(proc.signalCode, null);
    } finally {
      fs.rmSync = remove;
      proc.kill('SIGKILL');
      remove(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    }
  });
}

test('all browsers finish cleanup before a peer failure is reported', async () => {
  let finished = false;
  const failure = new Error('first browser cleanup failed');
  const browsers = [
    { close: async () => { throw failure; } },
    { close: async () => { await new Promise((resolve) => setTimeout(resolve, 20)); finished = true; } },
  ];
  await assert.rejects(closeBrowsers(browsers), (error) => error === failure);
  assert.ok(finished);
  assert.deepEqual(browsers, []);
});

for (const phase of ['send', 'websocket', 'endpoint', 'page', 'cleanup']) {
  test(`failed browser initialization cleans its unreturned browser: ${phase}`, async () => {
    const cleanupFails = phase === 'cleanup';
    const proc = Object.assign(new EventEmitter(), { pid: 424242, exitCode: null, signalCode: null });
    const initial = new Error('initial DevTools transport failed');
    const cleanup = new Error('profile removal failed');
    let kills = 0, removals = 0;
    const fakeProcess = Object.assign(new EventEmitter(), {
      kill(pid) {
        assert.equal(pid, -proc.pid);
        kills++;
        proc.signalCode = 'SIGKILL';
        queueMicrotask(() => proc.emit('exit'));
      },
    });
    const fakeFs = {
      mkdtempSync: () => '/tmp/fake-chrome', readFileSync: () => phase === 'endpoint' ? '' : '12345\n',
      rmSync() { removals++; if (cleanupFails) throw cleanup; },
    };
    class FakeSocket {
      constructor() { queueMicrotask(() => phase === 'websocket' ? this.onerror(initial) : this.onopen()); }
      send() { throw initial; }
      close() {}
    }
    const filename = path.resolve(__dirname, '../check-docs-sidebars.js');
    const context = {
      module: { exports: {} },
      require: (name) => name === 'node:fs' ? fakeFs : name === 'node:child_process' ? { spawn: () => proc } : require(name),
      process: fakeProcess, WebSocket: FakeSocket, clearTimeout,
      setTimeout: (fn, ms) => {
        if (ms === 100) { queueMicrotask(fn); return; }
        assert.ok(ms === 30000 || ms === 5000);
        return setTimeout(fn, 10);
      },
      fetch: async () => ({ json: async () => phase === 'page' ? [] : [{ type: 'page', webSocketDebuggerUrl: 'ws://fake' }] }),
    };
    vm.runInNewContext(fs.readFileSync(filename, 'utf8'), context, { filename });
    await assert.rejects(context.module.exports.launch('fake-chrome'), (error) => {
      if (phase === 'endpoint') return /started no DevTools endpoint in 60 s/.test(error.message);
      if (phase === 'page') return /opened no page in 30 s/.test(error.message);
      if (!cleanupFails) return error === initial;
      assert.deepEqual(Array.from(error.errors), [initial, cleanup]);
      assert.match(error.message, /initial DevTools transport failed.*profile removal failed/);
      return true;
    });
    assert.equal(kills, 1);
    assert.equal(removals, 1);
    assert.equal(fakeProcess.listenerCount('SIGINT'), 0);
    assert.equal(fakeProcess.listenerCount('SIGTERM'), 0);
  });
}
