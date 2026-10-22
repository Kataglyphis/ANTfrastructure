'use strict';

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { EventEmitter, once } = require('node:events');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
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
